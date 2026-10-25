#!/usr/bin/env bash
# 多路 CodeX 评审监控（配合 run-one.sh）。只报不杀：kill 一律先列清单给用户确认。
#
# 用法：monitor.sh <轮次目录> <路名>...      （用 run_in_background 挂起，退出即通知）
#   每 30s 采样一次所有路，状态取自 run-one.sh 写的 codex-<路名>.state：
#   exit 0  全部路结束，每路 rc=0、报告末行整行是 END_OF_REVIEW、启动验收通过
#   exit 2  某路日志超过 CODEX_MONITOR_IDLE 秒（默认 600）没增长（内存准入排队有心跳，不算停滞）
#   exit 3  某路评审进程下面又起了 codex exec（递归转包）
#   exit 4  启动验收不过（日志头的 model / provider / reasoning effort 不对，或 ultrafast 被降档），
#           或收尾时有路没有完整报告；走退回通道的那次尝试不查 provider 和档位，只提示一次
#   exit 5  某路没启动（超过 CODEX_MONITOR_START 秒仍无 state，默认 180），被终止（状态 aborted），
#           或进程没了但状态不是 finished
#   exit 6  其余都通过，但有路的提示词回显和 prompt 文件对不上，降档没法自动核：人工看日志开头，
#           核完再汇报；核不了就在汇报里写「档位未核实」
set -u
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "需要 bash >= 4.4" >&2; exit 1; }
D=$(cd "${1:?轮次目录}" && pwd -P) || exit 1
shift
[ $# -gt 0 ] || { echo "至少给一个路名" >&2; exit 1; }
IDLE_LIMIT=${CODEX_MONITOR_IDLE:-600}
START_LIMIT=${CODEX_MONITOR_START:-180}
declare -A NOTED=() UNVER=()

st() { sed -n "s/^$2=//p" "$D/codex-$1.state" 2>/dev/null | head -1; }
latest_log() { ls -t "$D"/codex-run-"$1".attempt*.log 2>/dev/null | head -1; }

# 启动验收。输出一行：PENDING / OK / FALLBACK / UNVERIFIED / BAD <原因>
# 只解析 codex 打印的头部块（两行 -------- 之间）；降档 warning 只在「提示词回显之后、模型第一次动作之前」
# 那一段里找，评审材料或正文里引用这句话不会误报。回显和提示词对不上时不猜，报 UNVERIFIED
check_header() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
log, prompt, model = sys.argv[1:4]
ansi = re.compile(r'\x1b\[[0-9;]*m')
L = [ansi.sub('', l.rstrip('\n')) for l in open(log, errors='replace')]
channel = 'official'
for l in L[:3]:
    m = re.match(r'\[run-one\] attempt=\d+ channel=(\w+)', l)
    if m: channel = m.group(1)
seps = [i for i, l in enumerate(L) if l == '--------'][:2]
if len(seps) < 2:
    print('PENDING'); sys.exit()
h = {}
for l in L[seps[0]+1:seps[1]]:
    k, _, v = l.partition(': ')
    h[k] = v
if h.get('model') != model:
    print(f"BAD 日志头 model 是 {h.get('model')!r}，期望 {model!r}"); sys.exit()
if h.get('reasoning effort') != 'xhigh':
    print(f"BAD 日志头 reasoning effort 是 {h.get('reasoning effort')!r}"); sys.exit()
if channel == 'fallback':
    print('FALLBACK'); sys.exit()
if h.get('provider') != 'openai':
    print(f"BAD 没走官方通道：provider={h.get('provider')!r}"); sys.exit()
pl = [ansi.sub('', l.rstrip('\n')) for l in open(prompt, errors='replace')]
pat = re.compile(r'^warning: .*service tier .*not advertised')
u = seps[1] + 1                      # 'user' 行，后面紧跟提示词回显（实测逐字一致）
if len(L) <= u + len(pl):            # 回显还没写完
    print('PENDING'); sys.exit()
if L[u:u+1] != ['user'] or L[u+1:u+1+len(pl)] != pl:
    print('UNVERIFIED'); sys.exit()
start = u + 1 + len(pl)
end = len(L)
for i in range(start, len(L)):
    if L[i] in ('codex', 'thinking', 'exec'):
        end = i; break
if any(pat.match(l) for l in L[start:end]):
    print('BAD ultrafast 被降档（出现 service tier not advertised warning）'); sys.exit()
print('OK')
PY
}

verify() { # verify <路名> <log> <final 0|1>：返回 0 通过，1 不通过（已打印原因）
  local t=$1 log=$2 final=$3 r
  r=$(check_header "$log" "$D/codex-review-prompt-$t.md" "$(st "$t" model)")
  case "$r" in
    OK) unset 'UNVER[$t]'; return 0 ;;
    PENDING) [ "$final" = 1 ] && { echo "ANOMALY $t: $(basename "$log") 没有完整的日志头"; return 1; }; return 0 ;;
    FALLBACK) unset 'UNVER[$t]'; [ -z "${NOTED[$t]:-}" ] && { echo "NOTE $t: 走了退回通道，这一路没有 ultrafast、联网搜索不可用"; NOTED[$t]=1; }; return 0 ;;
    UNVERIFIED) UNVER[$t]=1
                [ -z "${NOTED[$t]:-}" ] && { echo "NOTE $t: 日志里的提示词回显和 prompt 文件对不上，降档没法自动核，人工看 $(basename "$log") 开头"; NOTED[$t]=1; }; return 0 ;;
    *) echo "ANOMALY $t: ${r#BAD }（$(basename "$log")）"; return 1 ;;
  esac
}

# 只认「程序本身是 codex、子命令是 exec」的进程（选项可以带值）；包装脚本的 bash 阶段、
# timeout 前缀、codex 自带的 codex-code-mode-host、评审方跑的普通命令都不算
RE='^([^ ]*/)?codex( [^ ]+)* exec( |$)'
desc() { local c; for c in $(pgrep -P "$1"); do echo "$c"; desc "$c"; done; }

start=$(date +%s)
while :; do
  running=0
  for t in "$@"; do
    if [ ! -f "$D/codex-$t.state" ]; then
      if [ $(( $(date +%s) - start )) -ge "$START_LIMIT" ]; then
        echo "ANOMALY $t: ${START_LIMIT}s 内没有启动（没有 codex-$t.state）"; exit 5
      fi
      running=$((running+1)); continue
    fi
    case "$(st "$t" status)" in
      finished) continue ;;
      aborted) echo "ANOMALY $t: 被终止（状态 aborted，rc=$(st "$t" rc)）"; exit 5 ;;
    esac
    lp=$(st "$t" pid)
    if ! { tr '\0' ' ' < "/proc/$lp/cmdline"; } 2>/dev/null | command grep -q 'run-one\.sh'; then
      sleep 1   # 可能恰好在两次读取之间正常结束：重读一次状态
      case "$(st "$t" status)" in
        finished) continue ;;
        aborted) echo "ANOMALY $t: 被终止（状态 aborted，rc=$(st "$t" rc)）"; exit 5 ;;
      esac
      echo "ANOMALY $t: run-one.sh（pid=$lp）已经不在，但状态是 $(st "$t" status)"; exit 5
    fi
    running=$((running+1))
    log=$(latest_log "$t")
    [ -n "$log" ] || continue
    verify "$t" "$log" 0 || exit 4
    idle=$(( $(date +%s) - $(stat -c %Y "$log") ))
    if [ "$idle" -ge "$IDLE_LIMIT" ]; then
      echo "ANOMALY $t: $(basename "$log") 已 ${idle}s 没有增长；最后几行："
      tail -c 400 "$log" | sed 's/\x1b\[[0-9;]*m//g'
      exit 2
    fi
    top=""; nested=""
    for c in $(desc "$lp"); do
      a=$(ps -o args= -p "$c" 2>/dev/null) || continue
      printf '%s' "$a" | command grep -qE "$RE" || continue
      if [ -z "$top" ]; then top=$c; else nested=$c; break; fi
    done
    if [ -n "$nested" ]; then
      echo "ANOMALY $t: 评审进程 $top 下又起了 codex exec（pid=$nested）"
      ps -o pid=,lstart=,args= -p "$nested" 2>/dev/null
      exit 3
    fi
  done
  [ "$running" -eq 0 ] && break
  sleep 30
done

echo "全部路已结束，用时 $(( $(date +%s) - start ))s"
bad=0
for t in "$@"; do
  log=$(latest_log "$t")
  # 跑得快的路可能在两次采样之间就结束了，收尾时对最后一次尝试补做启动验收（以它为准，之前的标记作废）
  unset 'UNVER[$t]'
  if [ -z "$log" ] || ! verify "$t" "$log" 1; then bad=1; fi
  rc=$(st "$t" rc)
  if [ "$rc" = 0 ] && tail -n 1 "$D/codex-review-$t.md" 2>/dev/null | command grep -Fxq 'END_OF_REVIEW'; then
    echo "$t: ok（第 $(st "$t" attempt) 次尝试，通道 $(st "$t" channel)）"
  else
    echo "$t: 没有完整报告（rc=$rc）"; bad=1
  fi
done
command grep -E 'FALLBACK|gave_up|refused' "$D/run.trace" 2>/dev/null
[ "$bad" -eq 0 ] || exit 4
if [ ${#UNVER[@]} -gt 0 ]; then
  echo "降档未能自动核实的路：${!UNVER[*]}（人工核日志开头；核不了就在汇报里写「档位未核实」）"; exit 6
fi
exit 0
