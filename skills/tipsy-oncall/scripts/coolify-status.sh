#!/usr/bin/env bash
# coolify-status.sh — Coolify 应用状态与部署速览
# 值班速查:无参看全局,带 uuid 看单 app 细节 + 最近 5 次部署

set -euo pipefail

# 凭证统一从仓库外 secrets 文件注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
SECRETS_FILE="${TIPSY_ONCALL_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$SECRETS_FILE"
fi

usage() {
  cat <<'EOF'
用法:
  bash coolify-status.sh                    # 列出所有 app(uuid/name/status/last_deploy)
  bash coolify-status.sh <app-uuid>         # 查看单个 app 详情 + 最近 5 次部署
  bash coolify-status.sh -h | --help        # 显示帮助

说明:
  - 认证走 coolify context(coolify context use <name> 完成即可)
  - 兼容 $COOLIFY_URL / $COOLIFY_TOKEN(若已注入则由 coolify CLI 自行透传,本脚本不读取值)
  - 依赖:coolify CLI, jq

依赖缺失安装:
  brew install jq
  # coolify CLI 参考官方文档: https://coolify.io/docs/cli
EOF
}

# --help / -h 兜底
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# 依赖:coolify CLI
if ! command -v coolify >/dev/null 2>&1; then
  echo "[ERR] 未找到 coolify CLI,参考 https://coolify.io/docs/cli 安装后重试。" >&2
  exit 127
fi

# 依赖:jq
if ! command -v jq >/dev/null 2>&1; then
  echo "[ERR] 未找到 jq,请执行: brew install jq" >&2
  exit 127
fi

# 敏感变量注入探测:仅打印是否注入,绝不打印值
if [[ -n "${COOLIFY_TOKEN:-}" ]]; then
  echo "[INFO] 检测到 COOLIFY_TOKEN 已注入(值不打印)" >&2
fi
if [[ -n "${COOLIFY_URL:-}" ]]; then
  echo "[INFO] 检测到 COOLIFY_URL 已注入(值不打印)" >&2
fi

APP_UUID="${1:-}"

if [[ -z "$APP_UUID" ]]; then
  # 无参:全局 app 状态一屏
  echo "== Coolify Apps (全局速览) =="
  coolify --format json app list | jq -r '
    (["UUID","NAME","STATUS","LAST_DEPLOY"]),
    (.[] | [
      (.uuid // "-"),
      (.name // "-"),
      (.status // "-"),
      (.last_deployment_at // .updated_at // "-")
    ]) | @tsv
  ' | column -t -s $'\t'
  exit 0
fi

# 有参:单 app 详情 + 最近 5 次部署
echo "== App 详情: $APP_UUID =="
coolify --format json app get "$APP_UUID" | jq '{
  uuid,
  name,
  status,
  fqdn,
  git_repository,
  git_branch,
  build_pack,
  last_deployment_at,
  updated_at
}'

echo
echo "== 最近 5 次部署 =="
coolify --format json app deployments "$APP_UUID" | jq -r '
  (["DEPLOYMENT_UUID","STATUS","COMMIT","CREATED_AT"]),
  (.[:5][] | [
    (.uuid // "-"),
    (.status // "-"),
    ((.commit // "-") | .[0:8]),
    (.created_at // "-")
  ]) | @tsv
' | column -t -s $'\t'