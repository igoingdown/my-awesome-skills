#!/usr/bin/env bash
#
# tipsy-oncall / env-detect.sh
# 环境探测:三环境 secrets 全景 + preview URL 探活
#
#  - 无参:  列出 _PROD 与 _TEST 后缀变量的注入状态(仅 key 名,不打印值)
#  - tag:   构造 https://{tag}.api.dev.fantacy.live 并 curl -sI 探活
#  - URL:   直接探活并从 host 提取 tag,给出 SLS 过滤提示

set -euo pipefail

# ============ 用法 ============
usage() {
    cat <<'USAGE'
用法:
  env-detect.sh                    # 打印三环境 secrets 全景(prod/test/preview)
  env-detect.sh <tag>              # tag 形如 {commit_id}-{build},例如 abc1234-42
  env-detect.sh <preview_url>      # 例如 https://abc1234-42.api.dev.fantacy.live
  env-detect.sh --help | -h

说明:
  - 敏感变量(token/AK/SK 等)只判断是否注入,绝不打印其值
  - 凭证从 ~/github/my_dot_files/secrets.sh 注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
  - preview 环境按 commit tag 动态生成,无静态 secrets
USAGE
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
esac

# ============ 依赖检查 ============
# 缺失时给出 brew 提示,不额外污染输出
_need() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[error] 缺少依赖: $cmd" >&2
        echo "        请执行: brew install $pkg" >&2
        exit 1
    fi
}
_need curl

# ============ 顶部 source secrets ============
# 凭证统一从仓库外 secrets 文件注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
SECRETS_FILE="${TIPSY_ONCALL_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$SECRETS_FILE"
else
    echo "[warn] 未找到 secrets 文件: $SECRETS_FILE(所有变量将显示未注入)" >&2
fi

# ============ 工具函数 ============

# 只判断变量是否有值,绝不打印值本体
_print_key_status() {
    local key="$1"
    local val="${!key:-}"
    if [[ -n "$val" ]]; then
        printf '  %-44s [已注入]\n' "$key"
    else
        printf '  %-44s [未注入]\n' "$key"
    fi
}

# 扫描当前 shell 变量,列出所有以 suffix 结尾的 key
_scan_by_suffix() {
    local suffix="$1"
    local keys
    keys=$(compgen -A variable | grep -E "${suffix}\$" || true)
    if [[ -z "$keys" ]]; then
        echo "  (无匹配变量)"
        return
    fi
    while IFS= read -r k; do
        _print_key_status "$k"
    done <<< "$keys"
}

# curl -sI 探活,仅打印首行 HTTP 状态
_probe_url() {
    local url="$1"
    echo "[probe] $url"
    local line
    if line=$(curl -sI --max-time 6 "$url" 2>/dev/null | head -n 1 | tr -d '\r'); then
        if [[ -n "$line" ]]; then
            echo "  $line"
        else
            echo "  (无响应头,可能未部署或已下线)"
        fi
    else
        echo "  (curl 失败或超时)"
    fi
}

# 从 URL 中提取 host 首段作为 tag
_extract_tag() {
    local url="$1"
    local host="${url#*://}"
    host="${host%%/*}"
    echo "${host%%.*}"
}

# ============ 主流程 ============

arg="${1:-}"

if [[ -z "$arg" ]]; then
    echo "== PROD (生产环境, *_PROD) =="
    _scan_by_suffix "_PROD"
    echo
    echo "== TEST (测试环境, *_TEST) =="
    _scan_by_suffix "_TEST"
    echo
    echo "== PREVIEW (预览环境) =="
    echo "  (动态生成,按 commit tag,无静态 secrets)"
    echo "  用法: env-detect.sh {commit_id}-{build}   或   env-detect.sh <preview_url>"
    exit 0
fi

# tag 或 URL 分支
if [[ "$arg" =~ ^https?:// ]]; then
    url="$arg"
    tag="$(_extract_tag "$url")"
else
    tag="$arg"
    url="https://${tag}.api.dev.fantacy.live"
fi

_probe_url "$url"
echo
echo "[SLS 过滤提示]"
echo "  用 SLS 查这个 tag 应过滤 __tag__:_image_name_=${tag}"