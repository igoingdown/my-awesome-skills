#!/usr/bin/env bash
# scripts/es-search.sh
# 阿里云 ES 查询包装:走公网 endpoint + basic auth,输出原始 JSON,上层自行 pipe jq
# 用法见 --help

set -euo pipefail

# ---- 用法 ----
usage() {
  cat <<'EOF'
Usage: es-search.sh <env> <index_or_path> <query|-> [--op <_search|_count|_cat|_get>]

参数:
  env               prod | test
  index_or_path     索引名(如 tipsy_chat_v3);--op _cat 时可为空;--op _get 时形如 idx/_doc/id
  query             JSON 查询体;传 '-' 从 stdin 读;--op _cat / _get 传空串 '' 即可
  --op              操作类型:_search(默认) | _count | _cat | _get

依赖变量(从 ~/github/my_dot_files/secrets.sh 注入,不打印实际值):
  ALIYUN_ES_ENDPOINT_PROD / ALIYUN_ES_ENDPOINT_TEST   ES 公网 endpoint
  ALIYUN_ES_USERNAME / ALIYUN_ES_PASSWORD             basic auth 凭证
  ALIYUN_DMS_ES_URL_PROD                              endpoint 未开时 Chrome 兜底(仅提示)

示例:
  es-search.sh prod tipsy_chat_v3 '{"query":{"match_all":{}},"size":1}' | jq .
  cat q.json | es-search.sh prod tipsy_chat_v3 -
  es-search.sh prod tipsy_chat_v3 '{"query":{"term":{"userId":123}}}' --op _count
  es-search.sh prod '' '' --op _cat
  es-search.sh prod 'tipsy_chat_v3/_doc/abc123' '' --op _get
EOF
}

# 快速 --help 分支(不需要 secrets 就能看)
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
  esac
done

# ---- 依赖检查(仅 curl;jq 由上层管道自行使用) ----
if ! command -v curl >/dev/null 2>&1; then
  echo "缺失依赖: curl (macOS 通常自带; 若真的没有: brew install curl)" >&2
  exit 127
fi

# ---- 载入 secrets ----
# 凭证统一从仓库外 secrets 文件注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
SECRETS_FILE="${TIPSY_ONCALL_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$SECRETS_FILE"
fi

# ---- 参数解析 ----
if [[ $# -lt 3 ]]; then
  usage
  exit 64
fi

ENV_NAME="$1"
INDEX="$2"
QUERY="$3"
shift 3

OP="_search"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --op)
      [[ $# -ge 2 ]] || { echo "--op 需要一个参数值" >&2; exit 64; }
      OP="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 64
      ;;
  esac
done

# ---- 校验 env / endpoint(不 echo 值,只报变量名) ----
case "$ENV_NAME" in
  prod)
    ENDPOINT="${ALIYUN_ES_ENDPOINT_PROD:-}"
    FALLBACK="${ALIYUN_DMS_ES_URL_PROD:-(ALIYUN_DMS_ES_URL_PROD 未配置)}"
    ENV_LABEL="PROD"
    ;;
  test)
    ENDPOINT="${ALIYUN_ES_ENDPOINT_TEST:-}"
    FALLBACK="(测试环境暂无 Chrome 兜底, 请先在阿里云 ES 控制台开公网访问)"
    ENV_LABEL="TEST"
    ;;
  *)
    echo "env 必须是 prod 或 test, 实际: ${ENV_NAME}" >&2
    exit 64
    ;;
esac

if [[ -z "$ENDPOINT" ]]; then
  echo "ALIYUN_ES_ENDPOINT_${ENV_LABEL} 未注入或为空 → 未开公网访问, 走 Chrome 兜底: ${FALLBACK}" >&2
  exit 3
fi

if [[ -z "${ALIYUN_ES_USERNAME:-}" || -z "${ALIYUN_ES_PASSWORD:-}" ]]; then
  echo "ALIYUN_ES_USERNAME / ALIYUN_ES_PASSWORD 未注入" >&2
  exit 3
fi

# ---- query 支持 '-' 从 stdin 读 ----
if [[ "$QUERY" == "-" ]]; then
  QUERY="$(cat)"
fi

# ---- 组装 URL / METHOD ----
# 去掉 endpoint 末尾的 / 避免出现 //
ENDPOINT="${ENDPOINT%/}"

case "$OP" in
  _search|_count)
    if [[ -z "$INDEX" ]]; then
      echo "${OP} 需要指定 index" >&2
      exit 64
    fi
    URL="${ENDPOINT}/${INDEX}/${OP}"
    METHOD="POST"
    ;;
  _cat)
    # 空 index → 列所有索引; 否则拼到 _cat/ 后面
    if [[ -z "$INDEX" ]]; then
      URL="${ENDPOINT}/_cat/indices?v&s=index"
    else
      URL="${ENDPOINT}/_cat/${INDEX}?v"
    fi
    METHOD="GET"
    QUERY=""
    ;;
  _get)
    # INDEX 期望是完整路径, 例如 tipsy_chat_v3/_doc/xxx
    if [[ -z "$INDEX" ]]; then
      echo "_get 需要完整路径, 例如 tipsy_chat_v3/_doc/xxx" >&2
      exit 64
    fi
    URL="${ENDPOINT}/${INDEX}"
    METHOD="GET"
    QUERY=""
    ;;
  *)
    echo "--op 仅支持: _search | _count | _cat | _get, 实际: ${OP}" >&2
    exit 64
    ;;
esac

# ---- 发请求 ----
# -sS               静默但保留错误信息
# --max-time 30     避免挂死
# -u user:pw        basic auth, 凭证仅传给 curl 进程, 不会出现在 stdout/stderr
# --data-binary     原样发送, 不做 URL encode(区别于 --data)
curl_args=(
  -sS
  --max-time 30
  -u "${ALIYUN_ES_USERNAME}:${ALIYUN_ES_PASSWORD}"
  -H "Content-Type: application/json"
  -X "$METHOD"
  "$URL"
)
if [[ -n "$QUERY" ]]; then
  curl_args+=(--data-binary "$QUERY")
fi

# 输出原始响应(可能是 JSON, 也可能是 _cat 的纯文本), 上层自行 pipe jq / 处理
curl "${curl_args[@]}"