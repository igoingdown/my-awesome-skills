#!/usr/bin/env bash
# tipsy-oncall: memory 服务只读查询 (retrieve / summary)
# 只读,不做任何变更 —— DELETE / update 不在本 skill 职责内。

set -euo pipefail


usage() {
  cat <<'EOF'
tipsy-oncall memory 只读查询

用法:
  scripts/memory-retrieve.sh <env> <session_id> [character_id] [action]

参数:
  env           prod | test          目标环境
  session_id    string               会话 ID (必填)
  character_id  string (可选)        角色 ID;留空或不传则忽略
  action        retrieve | summary   默认 retrieve

示例:
  scripts/memory-retrieve.sh prod sess_123
  scripts/memory-retrieve.sh test sess_123 char_456 summary
  scripts/memory-retrieve.sh prod sess_123 "" summary

secrets 文件(默认 ~/github/my_dot_files/secrets.sh)需注入:
  TIPSY_MEMORY_URL_PROD  线上 memory 服务 base URL
  TIPSY_MEMORY_URL_TEST  测试 memory 服务 base URL
EOF
}

# --help / -h 快速返回
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

# 参数数量校验:至少要 env + session_id
if [[ $# -lt 2 ]]; then
  usage >&2
  exit 2
fi

ENV_NAME="$1"
SESSION_ID="$2"
CHARACTER_ID="${3:-}"
ACTION="${4:-retrieve}"

# 依赖检查:缺则给出 brew 提示后退出
require_cmd() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "缺少依赖: $cmd" >&2
    echo "安装: $hint" >&2
    exit 127
  fi
}

require_cmd curl "macOS 自带;若确实缺失可 brew install curl"
require_cmd python3 "brew install python3"

# 凭证统一从仓库外 secrets 文件注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
SECRETS_FILE="${TIPSY_ONCALL_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$SECRETS_FILE"
fi

# 选择目标 URL —— 错误消息只提变量名,不打印值,避免泄露
case "$ENV_NAME" in
  prod)
    URL="${TIPSY_MEMORY_URL_PROD:-}"
    URL_VAR="TIPSY_MEMORY_URL_PROD"
    ;;
  test)
    URL="${TIPSY_MEMORY_URL_TEST:-}"
    URL_VAR="TIPSY_MEMORY_URL_TEST"
    ;;
  *)
    echo "env 只支持 prod 或 test,收到: $ENV_NAME" >&2
    exit 2
    ;;
esac

if [[ -z "$URL" ]]; then
  echo "$URL_VAR 未注入,请检查 secrets.sh" >&2
  exit 1
fi

BASE_URL="${URL%/}"

# 请求分发
case "$ACTION" in
  retrieve)
    # POST /v1/memory/retrieve  body: {session_id, character_id?, k=10}
    # 用 python3 组装 JSON,避免手拼引号踩坑
    BODY="$(
      python3 - "$SESSION_ID" "$CHARACTER_ID" <<'PY'
import json, sys
sid, cid = sys.argv[1], sys.argv[2]
body = {"session_id": sid, "k": 10}
if cid:
    body["character_id"] = cid
print(json.dumps(body, ensure_ascii=False))
PY
    )"
    curl -sS \
      -X POST \
      -H "Content-Type: application/json" \
      --data "$BODY" \
      "${BASE_URL}/v1/memory/retrieve"
    ;;
  summary)
    # GET /v1/memory/summary?session_id=...&character_id=...
    ENCODED_SID="$(python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$SESSION_ID")"
    QUERY="session_id=${ENCODED_SID}"
    if [[ -n "$CHARACTER_ID" ]]; then
      ENCODED_CID="$(python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$CHARACTER_ID")"
      QUERY="${QUERY}&character_id=${ENCODED_CID}"
    fi
    curl -sS -X GET "${BASE_URL}/v1/memory/summary?${QUERY}"
    ;;
  *)
    echo "action 只支持 retrieve 或 summary,收到: $ACTION" >&2
    exit 2
    ;;
esac

# 末尾补一个换行,方便终端直接阅读
echo