#!/usr/bin/env bash
# mempoint-timeline.sh — 定位 mempoint 是"没入库 / 被 dedup / 被后续区间相交删了"
#
# 直查 PG 需要 Bytebase MCP(bash 里调不了),本脚本走 memory 服务 curl 拿快照。
# 完整时间线仍需主 agent 用 mcp__bytebase__query_database 查 tipsy_memory.mempoints 表。
#
# 用法示例:
#   bash mempoint-timeline.sh prod session-abc-123
#   bash mempoint-timeline.sh test session-xyz char-42

set -euo pipefail

# 凭证统一从仓库外 secrets 文件注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
SECRETS_FILE="${TIPSY_ONCALL_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$SECRETS_FILE"
fi

usage() {
  cat <<'EOF'
用法: mempoint-timeline.sh <env> <session_id> [character_id]

参数:
  env           prod | test
  session_id    必填
  character_id  可选,过滤到单个角色

功能:
  1. 打印 curl /v1/memory/retrieve → 当前能被检索到的 mempoints
  2. 打印 curl /v1/memory/summary  → 当前 summary 快照
  3. 打印 curl /v1/memory/debug/list(若存在) → 全量 mempoint 列表(不一定所有 env 都有)
  4. 打印主 agent 应该跑的 PG SQL 建议(通过 Bytebase MCP 完整时间线)

前置:
  source secrets.sh(TIPSY_MEMORY_URL_PROD / TIPSY_MEMORY_URL_TEST 已注入)

诊断决策:
  retrieve 有 + PG 有 = 一切正常
  retrieve 空 + PG 有 = 检索不到(embedding 问题 / dedup 问题)
  retrieve 空 + PG 空 = 没入库(backend 静默失败,查 sls-logs.md)
  retrieve 少 + PG 多 = 区间相交被删(读 llmdoc/multi-role-memory-design.md dedup 语义)
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" || $# -lt 2 ]]; then
  usage
  exit 0
fi

env_arg="$1"
session_id="$2"
character_id="${3:-}"

case "$env_arg" in
  prod) base_url="${TIPSY_MEMORY_URL_PROD:-}" ;;
  test) base_url="${TIPSY_MEMORY_URL_TEST:-}" ;;
  *)    echo "[error] env 必须是 prod 或 test" >&2; exit 2 ;;
esac

: "${base_url:?TIPSY_MEMORY_URL_${env_arg^^} 未注入,请填 secrets.sh}"

# ---- 1. retrieve ----
echo "==================== 1) /v1/memory/retrieve(检索视角)===================="
retrieve_body=$(printf '{"session_id":"%s"' "$session_id")
if [[ -n "$character_id" ]]; then
  retrieve_body+=$(printf ',"character_id":"%s"' "$character_id")
fi
retrieve_body+=',"k":20}'

curl -s -X POST "${base_url}/v1/memory/retrieve" \
  -H "Content-Type: application/json" \
  -d "$retrieve_body" \
  || echo "[error] retrieve 请求失败"

echo ""
echo ""

# ---- 2. summary ----
echo "==================== 2) /v1/memory/summary(摘要快照)===================="
summary_qs="session_id=${session_id}"
if [[ -n "$character_id" ]]; then
  summary_qs+="&character_id=${character_id}"
fi

curl -s -G "${base_url}/v1/memory/summary" --data-urlencode "session_id=${session_id}" \
  ${character_id:+--data-urlencode "character_id=${character_id}"} \
  || echo "[error] summary 请求失败"

echo ""
echo ""

# ---- 3. debug/list(若存在)----
echo "==================== 3) /v1/memory/debug/list(可选,若存在)===================="
debug_code=$(curl -s -o /dev/null -w '%{http_code}' -G "${base_url}/v1/memory/debug/list" \
  --data-urlencode "session_id=${session_id}" \
  ${character_id:+--data-urlencode "character_id=${character_id}"} || echo 000)

if [[ "$debug_code" == "200" ]]; then
  curl -s -G "${base_url}/v1/memory/debug/list" \
    --data-urlencode "session_id=${session_id}" \
    ${character_id:+--data-urlencode "character_id=${character_id}"}
  echo ""
else
  echo "[info] debug endpoint 不可用(HTTP $debug_code),跳过。完整时间线走下一步 PG 查询。"
fi

echo ""
echo ""

# ---- 4. PG 查询建议(主 agent 用 Bytebase MCP 跑)----
cat <<PGSUGGEST
==================== 4) PG 完整时间线(主 agent 用 Bytebase MCP 跑)====================

请把下面这段 SQL 通过 mcp__bytebase__query_database 跑:

  database = "tipsy_memory"
  instance = "tipsy-memory"
  statement:
    SELECT
      id,
      session_id,
      character_id,
      LEFT(content, 60) AS content_head,
      extra->>'batch_turns' AS batch_turns,
      extra->>'start_turn'  AS start_turn,
      extra->>'end_turn'    AS end_turn,
      extra->>'dedup_key'   AS dedup_key,
      created_at
    FROM mempoints
    WHERE session_id = '${session_id}'
    ${character_id:+AND character_id = '${character_id}'}
    ORDER BY created_at ASC
    LIMIT 200;

诊断:
  - 每条 mempoint 的 [start_turn, end_turn] 是它覆盖的对话区间(batchTurns=4)
  - 若两条 mempoint 区间相交,后写的会删前面的(设计如此)
  - dedup_key 相同的 ingest 会被拦(重投保护)
  - created_at 是 UTC,SLS 是 UTC+8,对齐时序时注意
PGSUGGEST
