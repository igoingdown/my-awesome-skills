#!/usr/bin/env bash
# trace-crosslink.sh — 给定 trace_id，输出 SLS / SigNoz / Logfire 三路查询建议
# 脚本本身不调 MCP，只生成查询语句，供主 agent 复制到对应工具中执行

set -euo pipefail

# 凭证统一从仓库外 secrets 文件注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
SECRETS_FILE="${TIPSY_ONCALL_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$SECRETS_FILE"
fi

# ===== 使用说明 =====
usage() {
  cat <<'EOF'
用法: trace-crosslink.sh <trace_id> [env] [time_range]

参数:
  trace_id     必填，OpenTelemetry trace id
  env          可选，prod | test，默认 prod
  time_range   可选，时间范围，默认 30m（示例：30m / 1h / 6h）

选项:
  -h, --help   查看帮助

示例:
  trace-crosslink.sh 0af7651916cd43dd8448eb211c80319c
  trace-crosslink.sh 0af7651916cd43dd8448eb211c80319c prod 1h
  trace-crosslink.sh 0af7651916cd43dd8448eb211c80319c test 30m

说明:
  脚本只打印查询建议，主 agent 需要把建议复制到对应 MCP 工具执行:
    - SLS    → mcp__aliyun-sls__sls_execute_sql
    - SigNoz → mcp__signoz__signoz_get_trace_details / signoz_search_logs
    - Logfire → 走 logfire-ops skill 的 query_run
EOF
}

# ===== 参数解析 =====
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    echo "错误：缺少 trace_id 参数" >&2
    usage
    exit 1
    ;;
esac

TRACE_ID="$1"
ENV_NAME="${2:-prod}"
TIME_RANGE="${3:-30m}"

# ===== 校验 env =====
if [[ "$ENV_NAME" != "prod" && "$ENV_NAME" != "test" ]]; then
  echo "错误：env 只能是 prod 或 test，当前：${ENV_NAME}" >&2
  exit 1
fi

# ===== 软性依赖提示（脚本本身不用，但主 agent 后续查询可能用到） =====
check_dep() {
  local bin="$1"
  local brew_pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "提示：未检测到 ${bin}，建议：brew install ${brew_pkg}" >&2
  fi
}
check_dep python3 python@3
check_dep jq jq
check_dep coolify coolify

# ===== SLS 环境配置（按 env 切 project/logStore/regionId） =====
if [[ "$ENV_NAME" == "prod" ]]; then
  SLS_PROJECT="tipsy-prod"
  SLS_LOGSTORE="tipsy-backend"
  SLS_REGION="cn-shanghai"
else
  SLS_PROJECT="tipsy-test"
  SLS_LOGSTORE="tipsy-backend"
  SLS_REGION="cn-shanghai"
fi

# ===== 打印三路查询建议 =====
cat <<EOF
=======================================================
Trace 跨平台查询建议
  trace_id   : ${TRACE_ID}
  环境       : ${ENV_NAME}
  时间范围   : now-${TIME_RANGE} → now
=======================================================

[1] SLS（阿里云日志服务）
    工具: mcp__aliyun-sls__sls_execute_sql
    参数:
      project    = ${SLS_PROJECT}
      logStore   = ${SLS_LOGSTORE}
      regionId   = ${SLS_REGION}
      from_time  = now-${TIME_RANGE}
      to_time    = now
      limit      = 100
      query      = trace_id: '${TRACE_ID}'

[2] SigNoz
    优先: mcp__signoz__signoz_get_trace_details
      traceId    = ${TRACE_ID}
    回退（trace 不在 SigNoz 但相关日志可能命中）:
      mcp__signoz__signoz_search_logs
      query      = trace_id='${TRACE_ID}'

[3] Logfire（走 logfire-ops skill）
    query_run SQL:
      SELECT * FROM records WHERE trace_id='${TRACE_ID}' LIMIT 100

=======================================================
说明：脚本只生成查询建议，主 agent 请复制到相应 MCP 工具执行。
     具体 SLS project/logStore/region 若与实际不一致，请按环境配置修正。
EOF