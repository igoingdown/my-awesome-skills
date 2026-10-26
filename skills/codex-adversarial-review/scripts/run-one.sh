#!/usr/bin/env bash
# 单路 CodeX 评审 + 重试包装（固定配置：官方订阅通道 + gpt-6.1-sol + ultrafast + xhigh）。
#
# 用法：run-one.sh <轮次目录> <路名> <pack|code> [--search]
#   读  <轮次目录>/codex-review-prompt-<路名>.md
#   写  <轮次目录>/codex-review-<路名>.md          报告（codex -o 落盘，末行必须整行是 END_OF_REVIEW）
#       <轮次目录>/codex-run-<路名>.attempt<N>.log  每次尝试的日志
#       <轮次目录>/codex-<路名>.state              本路状态（monitor.sh 读）：pid / model / attempt / channel / status / rc
#       <轮次目录>/run.trace                       事件记录（ok / fail / FALLBACK / gave_up / refused），只供人看
#   pack：材料已打进 prompt；关 shell 和子代理、不读用户 config、--ephemeral；写文件被 read-only 策略拒绝
#   code：读仓库、跑测试；必须设 CODEX_REVIEW_REPO=<仓库根>。关闭沙箱，只做配置隔离（见 references/codex-invocation.md）
#   同一轮次目录里每个路名只能跑一次；重跑换新轮次目录（r<N+1>），脚本不覆盖旧产物。
#
# 可选环境变量：
#   CODEX_REVIEW_MODEL             默认 gpt-6.1-sol
#   CODEX_REVIEW_TIMEOUT           官方通道单次尝试秒数，pack 默认 1500、code 默认 3000（不含内存准入排队）
#   CODEX_REVIEW_FALLBACK_TIMEOUT  退回通道单次尝试秒数，默认 4200
#   CODEX_REVIEW_FALLBACK          退回配置（bash 文件，定义 FALLBACK_ARGS 数组和 KEEP_ENV 变量名），
#                                  默认 ~/.config/codex-review/fallback.sh；不存在就不退回
#   CODEX_REVIEW_RETRY_SLEEP       两次尝试之间等几秒，默认 60
#   CODEX_BIN                      默认 codex（本机应解析到带内存准入的包装脚本）
set -u
umask 077

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "需要 bash >= 4.4" >&2; exit 2
fi

usage() { echo "用法：run-one.sh <轮次目录> <路名> <pack|code> [--search]" >&2; exit 2; }
[ $# -eq 3 ] || [ $# -eq 4 ] || usage
[ $# -eq 3 ] || [ "$4" = "--search" ] || usage
case "$3" in pack|code) MODE=$3 ;; *) usage ;; esac
D=$(cd "$1" 2>/dev/null && pwd -P) || { echo "轮次目录不存在：$1" >&2; exit 2; }
T=$2
SEARCH_TOP=(); SEARCH_EXEC=()
if [ $# -eq 4 ]; then SEARCH_TOP=(--search); SEARCH_EXEC=(-c 'web_search="live"'); fi

[[ $T =~ ^[A-Za-z0-9_-]+$ ]] || { echo "路名只能含字母、数字、_ 和 -" >&2; exit 2; }
case "$D" in /tmp|/tmp/*|/dev/shm|/dev/shm/*) echo "轮次目录不能放在 /tmp 或 /dev/shm（内存盘）" >&2; exit 2 ;; esac
[[ $D == *[\"\\[:cntrl:]]* ]] && { echo "轮次目录路径不能含双引号、反斜杠或控制字符" >&2; exit 2; }
# 轮次目录必须是自己的、别人写不进去（目录里的文件都按普通路径写，不防同目录里预置的符号链接）
[ -O "$D" ] && [ -z "$(find "$D" -maxdepth 0 -perm /022)" ] || { echo "轮次目录必须属于自己且组和其他人不可写（建议 mkdir -m 700）" >&2; exit 2; }
if [ "$MODE" = code ] && [ -z "${CODEX_REVIEW_REPO:-}" ]; then echo "code 模式要设 CODEX_REVIEW_REPO=<仓库根>" >&2; exit 2; fi

MODEL=${CODEX_REVIEW_MODEL:-gpt-6.1-sol}
BIN=${CODEX_BIN:-codex}
RETRY_SLEEP=${CODEX_REVIEW_RETRY_SLEEP:-60}
FALLBACK_FILE=${CODEX_REVIEW_FALLBACK:-$HOME/.config/codex-review/fallback.sh}
PROMPT="$D/codex-review-prompt-$T.md"
OUT="$D/codex-review-$T.md"
STATE="$D/codex-$T.state"
TRACE="$D/run.trace"

[ -f "$PROMPT" ] || { echo "缺少 $PROMPT" >&2; exit 2; }
# 先原子占位：同一轮次目录里同名路只能启动一次，并发启动时只有一个能拿到。
# 用 bash 的 noclobber（O_EXCL）建锁文件；不用 mkdir：本机 mkdir 是 uutils 0.8.0，并发时两边都可能成功
if ! ( set -o noclobber; : > "$D/.lock-$T" ) 2>/dev/null || compgen -G "$D/codex-run-$T.attempt*" > /dev/null || [ -e "$OUT" ] || [ -e "$STATE" ]; then
  echo "轮次目录里已有路 $T 的产物；重跑请换新轮次目录或新路名" >&2; exit 2
fi
# 任务书上限 1,048,576 字符（不是字节），超了 codex 返回 input_too_large 且 rc 仍为 0；留 5% 余量
chars=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$PROMPT")
if [ "$chars" -gt 996000 ]; then
  echo "$(date +%T) $T refused prompt_chars=$chars" >> "$TRACE"
  echo "prompt $chars 字符，超过 996000，先按分面拆小或压缩原始证据" >&2
  exit 2
fi

attempt=0; channel=official; status=starting; rc=; cpid=
write_state() {
  printf 'pid=%s\nmodel=%s\nattempt=%s\nchannel=%s\nstatus=%s\nrc=%s\n' \
    "$$" "$MODEL" "$attempt" "$channel" "$status" "$rc" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
}
# 收到 TERM/INT/HUP：转发给正在跑的这一次尝试，等它退出，状态记 aborted（监控按异常报）
on_signal() {
  trap - TERM INT HUP
  [ -n "$cpid" ] && kill -TERM "$cpid" 2>/dev/null && wait "$cpid" 2>/dev/null
  status=aborted; rc=signal; write_state
  echo "$(date +%T) $T aborted attempt=$attempt（收到终止信号）" >> "$TRACE"
  exit 143
}
trap on_signal TERM INT HUP
trap '[ "$status" = finished ] || [ "$status" = aborted ] || { status=aborted; rc=${rc:-unknown}; write_state; }' EXIT
write_state || exit 2
mkdir -p "$D/tmp-$T" || exit 2

COMMON=(-m "$MODEL" -c 'model_reasoning_effort="xhigh"' -c 'service_tier="ultrafast"'
        --enable ultrafast_mode --ignore-user-config --skip-git-repo-check
        -c 'agents.enabled=false' --disable multi_agent --disable multi_agent_v2)   # 关掉进程内子代理
# 官方订阅通道显式固定，不依赖 config.toml；退回时整组换成 FALLBACK_ARGS
CHANNEL_ARGS=(-c 'model_provider="openai"' -c 'forced_login_method="chatgpt"')
case "$MODE" in
  pack)
    mkdir -p "$D/empty" || exit 2
    MODE_ARGS=(--sandbox read-only --ephemeral --cd "$D/empty")
    for f in shell_tool unified_exec unified_exec_tty apps plugins remote_plugin \
             browser_use browser_use_external browser_use_full_cdp_access computer_use \
             image_generation view_image in_app_browser workspace_dependencies goals \
             hooks skill_search tool_suggest; do
      MODE_ARGS+=(--disable "$f")
    done
    TIMEOUT=${CODEX_REVIEW_TIMEOUT:-1500}
    ;;
  code)
    REPO=$CODEX_REVIEW_REPO
    mkdir -p "$D/home-$T" || exit 2
    # allow_login_shell=false：评审方命令不走 bash -l，否则 /etc/profile.d 会把 TMPDIR 改回 /var/tmp（10-26 实测）
    MODE_ARGS=(-c 'allow_login_shell=false' -c 'shell_environment_policy.inherit="core"'
               -c "shell_environment_policy.set.HOME=\"$D/home-$T\""
               -c "shell_environment_policy.set.TMPDIR=\"$D/tmp-$T\""
               -c 'shell_environment_policy.set.KUBECONFIG="/nonexistent/kubeconfig"'
               --cd "$REPO" --dangerously-bypass-approvals-and-sandbox)
    TIMEOUT=${CODEX_REVIEW_TIMEOUT:-3000}
    ;;
  *) echo "模式只能是 pack 或 code" >&2; exit 2 ;;
esac

# 环境变量按白名单传：官方通道用 ~/.codex 下的 ChatGPT 登录态，不需要任何 key/token 变量。
# 在子 shell 里用 bash 内建 export -n 取消白名单外变量和函数的导出（脚本内部同名变量的值不受影响）再 exec，
# 变量值不会出现在任何进程的命令行参数里
KEEP_ENV=""
launch() {
  local v keep=" HOME PATH USER LOGNAME LANG LC_ALL LC_CTYPE TZ $KEEP_ENV "
  # shellcheck disable=SC2163  # 这里就是按变量名间接取消导出
  for v in $(compgen -e); do
    [[ $keep == *" $v "* ]] || export -n "$v" || { echo "[run-one] 无法取消导出 $v" >> "$LOG"; exit 2; }
  done
  # shellcheck disable=SC2163
  for v in $(compgen -A function); do export -nf "$v"; done
  export TERM=dumb KUBECONFIG=/nonexistent/kubeconfig TMPDIR="$D/tmp-$T"
  exec timeout --kill-after=60 "$t_limit" "$BIN" "${SEARCH_TOP[@]}" exec "${COMMON[@]}" "${SEARCH_EXEC[@]}" \
    "${CHANNEL_ARGS[@]}" "${MODE_ARGS[@]}" -o "$OUT" - < "$PROMPT" >> "$LOG" 2>&1
}

# 内存准入：先在这里排队（每分钟往日志写一行心跳，监控不会误判停滞），排到了再开始计时
admission_wait() {
  command -v memory-admission > /dev/null || return 0
  local waited=0
  until memory-admission check > /dev/null 2>&1; do
    [ "$waited" -ge 1800 ] && return 1
    echo "[run-one] $(date +%T) 内存准入排队中（已等 ${waited}s）" >> "$1"
    sleep 60; waited=$((waited+60))
  done
}

# 官方通道鉴权失败的特征：顶格 ERROR: 行；只看提示词回显之后的部分（材料里引用的同样行不算）
AUTH_RE='^ERROR: (unexpected status (401|403)|Failed to refresh token|.*unsupported_country_region_territory|.*Country, region, or territory not supported|.*(log ?in again|not logged in))'

max=4
while [ "$attempt" -lt "$max" ]; do
  attempt=$((attempt+1))
  LOG="$D/codex-run-$T.attempt$attempt.log"
  status=queued; write_state
  echo "[run-one] attempt=$attempt channel=$channel model=$MODEL mode=$MODE" >> "$LOG"
  if ! admission_wait "$LOG"; then
    echo "$(date +%T) $T fail attempt=$attempt 内存准入排队超过 30 分钟" >> "$TRACE"
    [ "$attempt" -lt "$max" ] && sleep "$RETRY_SLEEP"
    continue
  fi
  status=running; write_state
  [ "$channel" = fallback ] && t_limit=${CODEX_REVIEW_FALLBACK_TIMEOUT:-4200} || t_limit=$TIMEOUT
  ( trap - TERM INT HUP EXIT; launch ) &
  cpid=$!
  wait "$cpid"; rc=$?; cpid=
  if [ $rc -eq 0 ] && tail -n 1 "$OUT" 2>/dev/null | command grep -Fxq 'END_OF_REVIEW'; then
    echo "$(date +%T) $T ok attempt=$attempt channel=$channel" >> "$TRACE"
    status=finished; write_state
    exit 0
  fi
  echo "$(date +%T) $T fail attempt=$attempt channel=$channel rc=$rc" >> "$TRACE"
  [ -f "$OUT" ] && mv -f "$OUT" "$D/codex-review-$T.attempt$attempt.partial.md"
  auth_fail=0
  if [ $rc -ne 0 ] && [ $rc -ne 124 ] && [ $rc -ne 137 ] && \
     sed 's/\x1b\[[0-9;]*m//g' "$LOG" | awk -v n="$(awk 'END{print NR}' "$PROMPT")" \
       '$0=="--------"{s++; if(s==2){skip=NR+1+n}} NR>skip' | tail -n 200 | command grep -qE "$AUTH_RE"; then
    auth_fail=1
  fi
  if [ $auth_fail -eq 1 ] && [ "$channel" = official ]; then
    FALLBACK_ARGS=(); KEEP_ENV=""
    # shellcheck source=/dev/null
    [ -f "$FALLBACK_FILE" ] && . "$FALLBACK_FILE"
    if [ ${#FALLBACK_ARGS[@]} -gt 0 ]; then
      channel=fallback; CHANNEL_ARGS=("${FALLBACK_ARGS[@]}")
      max=$((attempt+2))   # 退回通道单独给 2 次尝试
      echo "$(date +%T) $T FALLBACK 官方通道鉴权失败，后续尝试走退回通道（没有 ultrafast，联网搜索不可用）" >> "$TRACE"
      continue
    fi
    echo "$(date +%T) $T gave_up auth_fail 官方通道鉴权失败且没有退回配置，需要重新登录：! codex login" >> "$TRACE"
    rc=auth_fail; status=finished; write_state; exit 4
  fi
  if [ $auth_fail -eq 1 ]; then
    echo "$(date +%T) $T gave_up auth_fail 退回通道也鉴权失败，需要重新登录：! codex login" >> "$TRACE"
    rc=auth_fail; status=finished; write_state; exit 4
  fi
  [ "$attempt" -lt "$max" ] && sleep "$RETRY_SLEEP"
done
echo "$(date +%T) $T gave_up" >> "$TRACE"
status=finished; write_state
exit 1
