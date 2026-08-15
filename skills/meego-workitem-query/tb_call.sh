#!/usr/bin/env bash
# tool-bridge 通用调用器：渐进发现（~help / ~tree）+ 调用任意节点。
# 凭据从 env 读，未设则 source secrets.sh：TB_BASE_URL / TB_SK。
# 用法:
#   bash tb_call.sh tree [depth]           # GET /~tree?depth=N（默认 2，受权限裁剪）
#   bash tb_call.sh help [path]            # GET /<path>/~help（省略 path = 根 ~help）
#   bash tb_call.sh call <path> '<json>'   # POST /<path>，body 即 arguments 本体
#   bash tb_call.sh get  <path>            # GET /<path>（原样透传）
# SK 经 curl -K stdin 传，不进 ps / 命令历史。
set -euo pipefail
SECRETS_FILE="${SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -z "${TB_SK:-}" || -z "${TB_BASE_URL:-}" ]]; then
  [[ -f "$SECRETS_FILE" ]] && { set +u; # shellcheck disable=SC1090
    source "$SECRETS_FILE"; set -u; }
fi
: "${TB_BASE_URL:?缺少 TB_BASE_URL（你的 tool-bridge 网关地址，放 secrets.sh）}"
: "${TB_SK:?缺少 TB_SK：先浏览器登录 \$TB_BASE_URL/login 拿 key，见 TUTORIAL.md}"
command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }
BASE="${TB_BASE_URL%/}"

tb() {  # $1=method  $2=path(带 query)  $3=body(可选)
  local m="$1" p="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$TB_SK" | \
      curl -sS -m 60 -K - -X "$m" "$BASE/$p" -H 'Content-Type: application/json' -d "$body"
  else
    printf 'header = "Authorization: Bearer %s"\n' "$TB_SK" | \
      curl -sS -m 60 -K - -X "$m" "$BASE/$p"
  fi
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  tree) tb GET "~tree?depth=${1:-2}";;
  help) p="${1:-}"; if [[ -n "$p" ]]; then tb GET "${p%/}/~help"; else tb GET "~help"; fi;;
  call) tb POST "${1:?缺 path}" "${2:?缺 json arguments}";;
  get)  tb GET "${1:?缺 path}";;
  *) echo "未知子命令: $cmd（可用: tree | help | call | get）" >&2; exit 1;;
esac
