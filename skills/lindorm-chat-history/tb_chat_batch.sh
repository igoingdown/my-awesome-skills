#!/usr/bin/env bash
# 批量拉多个 UID 的聊天原文（经 tool-bridge 宽表 SQL 查询，含 sender_type），落本机。
# 严格【串行】+ UID 间限速——绝不并发（devbox 纪律：网关单容器 + 共享 Lindorm 扛不住 fan-out）。
#
# 用法:
#   bash tb_chat_batch.sh --uids "u1,u2,..." [选项]
#   bash tb_chat_batch.sh --uid-file uids.txt [选项]     # 每行一个 UID
# 选项:
#   --size <n>        每个 UID 取近期 n 条（默认 1000）
#   --reversed        传入的已是 rev_user_id（含负数）；否则按 user_id 反转
#   --index <table>   宽表名（默认取 env LINDORM_TB_DEFAULT_TABLE）
#   --outdir <dir>    输出目录（默认 ./tb_chat_out），每个 UID 一个 <uid>.jsonl
#   --sleep <sec>     UID 之间的间隔秒数（默认 1，限速护共享 devbox）
#   --secrets <path>  透传给 query_chat_history.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
UIDS=""; UID_FILE=""; SIZE=1000; REVERSED=""; INDEX=""; OUTDIR="./tb_chat_out"; SLP=1; SECRETS=""
die(){ echo "ERROR: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uids) UIDS="${2:?}"; shift 2;;
    --uid-file) UID_FILE="${2:?}"; shift 2;;
    --size) SIZE="${2:?}"; shift 2;;
    --reversed) REVERSED="--reversed"; shift;;
    --index) INDEX="${2:?}"; shift 2;;
    --outdir) OUTDIR="${2:?}"; shift 2;;
    --sleep) SLP="${2:?}"; shift 2;;
    --secrets) SECRETS="${2:?}"; shift 2;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) die "未知参数: $1";;
  esac
done

# 收集 UID 列表
list=()
if [[ -n "$UID_FILE" ]]; then
  [[ -f "$UID_FILE" ]] || die "找不到 uid 文件: $UID_FILE"
  while IFS= read -r line; do line="$(echo "$line" | tr -d '[:space:]')"; [[ -n "$line" ]] && list+=("$line"); done < "$UID_FILE"
fi
if [[ -n "$UIDS" ]]; then
  IFS=',' read -ra arr <<< "$UIDS"
  for u in "${arr[@]}"; do u="$(echo "$u" | tr -d '[:space:]')"; [[ -n "$u" ]] && list+=("$u"); done
fi
[[ ${#list[@]} -gt 0 ]] || die "没有 UID。用 --uids 或 --uid-file 提供。"

mkdir -p "$OUTDIR"
echo "共 ${#list[@]} 个 UID，串行处理，每个取近期 $SIZE 条 → $OUTDIR/（UID 间隔 ${SLP}s）" >&2
extra=(); [[ -n "$INDEX" ]] && extra+=(--index "$INDEX"); [[ -n "$SECRETS" ]] && extra+=(--secrets "$SECRETS")

i=0; ok=0
for u in "${list[@]}"; do
  i=$((i+1))
  # 文件名安全化（负号/特殊字符换成 _）
  safe="$(printf '%s' "$u" | tr -c 'A-Za-z0-9_-' '_')"
  out="$OUTDIR/${safe}.jsonl"
  echo "[$i/${#list[@]}] UID=$u → $out" >&2
  if bash "$HERE/query_chat_history.sh" "$u" $REVERSED --backend tool-bridge \
        --size "$SIZE" --export "$out" "${extra[@]}" >&2; then
    cnt="$(wc -l < "$out" | tr -d ' ')"
    echo "    ✓ $cnt 条" >&2; ok=$((ok+1))
  else
    echo "    ✗ 失败（见上）" >&2
  fi
  [[ $i -lt ${#list[@]} ]] && sleep "$SLP"   # 最后一个不用等
done
echo "完成：${ok}/${#list[@]} 个 UID 成功，产物在 $OUTDIR/" >&2
