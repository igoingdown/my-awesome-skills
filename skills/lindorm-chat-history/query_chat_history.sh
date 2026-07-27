#!/usr/bin/env bash
# 按 UID 查 Lindorm(LindormSearch, ES 兼容) 里的用户聊天原文。
#
# 关键背景（踩过的坑，别再踩）：
#   - 端点是 LindormSearch 搜索引擎(proxy-search, 默认 30070)，不是 LindormTable SQL。
#     必须走 ES 兼容 REST，lindorm-cli 对它无效(会报 parse url failed)。
#   - 有些部署会把用户 ID【十进制字符串整体反转】后再入库(打散分片、避免写热点)，
#     存进 rev_user_id 之类的字段。若你的索引这么做，脚本默认会先反转 UID 再匹配；
#     若你手上已经是反转值，用 --reversed 跳过；若索引直接存原始 UID，设 LINDORM_USER_FIELD
#     指向原始字段并传 --reversed。
#   - 某些索引 _source 被关闭(enabled:false)，默认命中不返回文档，必须用 docvalue_fields
#     显式点字段。脚本已按 docvalue 取值。
#   - 若 content 是 keyword 且设了 ignore_above，超长的单条消息不会进该字段索引。
#
# 索引名与字段名都通过环境变量注入（放本地 secrets，不进仓库），见 secrets.example.sh。
#
# 用法:
#   query_chat_history.sh <uid> [选项]
#     <uid>                    用户 ID（默认反转后匹配 LINDORM_USER_FIELD）
#   选项:
#     --reversed               传入的已是反转后的值(或索引存原始 UID)，不再反转
#     --index <name>           覆盖索引名（默认取 env LINDORM_CHAT_INDEX）
#     --conversation <id>      只看某个会话 ID
#     --size <n>               单页条数，默认 20（导出模式忽略）
#     --count                  只输出命中总数
#     --export <file>          翻页导出全部命中到 JSONL 文件(search_after)
#     --raw                    直接输出 ES 原始 JSON（不做 jq 美化）
#     --secrets <path>         指定 secrets 文件，默认 ~/github/my_dot_files/secrets.sh
#   环境变量: SECRETS_FILE 同 --secrets
set -euo pipefail

SECRETS_FILE="${SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
INDEX_OVERRIDE=""
CONV=""
SIZE=20
MODE="page"      # page | count | export
EXPORT_FILE=""
REVERSED=0
RAW=0
UID_IN=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reversed) REVERSED=1; shift;;
    --index) INDEX_OVERRIDE="${2:?}"; shift 2;;
    --conversation) CONV="${2:?}"; shift 2;;
    --size) SIZE="${2:?}"; shift 2;;
    --count) MODE="count"; shift;;
    --export) MODE="export"; EXPORT_FILE="${2:?}"; shift 2;;
    --raw) RAW=1; shift;;
    --secrets) SECRETS_FILE="${2:?}"; shift 2;;
    -h|--help) sed -n '2,35p' "$0"; exit 0;;
    -*) die "未知选项: $1";;
    *) [[ -z "$UID_IN" ]] && UID_IN="$1" || die "多余参数: $1"; shift;;
  esac
done

[[ -n "$UID_IN" ]] || die "缺少 UID。用法: $0 <uid> [选项]，见 --help"
[[ "$UID_IN" =~ ^[0-9]+$ ]] || die "UID 必须是纯数字十进制字符串: $UID_IN"

# 凭据/配置：优先用已注入的 env，否则 source secrets 文件（只引用键名，不回显值）
if [[ -z "${LINDORM_ENDPOINT_URL:-}" || -z "${LINDORM_USER:-}" || -z "${LINDORM_PASSWORD:-}" ]]; then
  [[ -f "$SECRETS_FILE" ]] || die "找不到 secrets 文件: $SECRETS_FILE（参考 secrets.example.sh）"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
fi
: "${LINDORM_ENDPOINT_URL:?secrets 缺少 LINDORM_ENDPOINT_URL}"
: "${LINDORM_USER:?secrets 缺少 LINDORM_USER}"
: "${LINDORM_PASSWORD:?secrets 缺少 LINDORM_PASSWORD}"

# 索引名与字段名从 env 注入，带通用默认；真实内部命名放本地 secrets，不进仓库
IDX="${INDEX_OVERRIDE:-${LINDORM_CHAT_INDEX:?secrets 缺少 LINDORM_CHAT_INDEX（索引名），或用 --index 指定}}"
USER_FIELD="${LINDORM_USER_FIELD:-rev_user_id}"
CONV_FIELD="${LINDORM_CONV_FIELD:-conversation_id}"
SEQ_FIELD="${LINDORM_SEQ_FIELD:-sequence}"
CONTENT_FIELD="${LINDORM_CONTENT_FIELD:-content}"
# 额外要取的字段，逗号分隔，可选
EXTRA_FIELDS="${LINDORM_EXTRA_FIELDS:-}"

command -v curl >/dev/null || die "需要 curl"
HAVE_JQ=0; command -v jq >/dev/null && HAVE_JQ=1

if [[ "$REVERSED" -eq 1 ]]; then
  REV="$UID_IN"
else
  REV="$(printf '%s' "$UID_IN" | rev)"
fi

BASE="$LINDORM_ENDPOINT_URL"

# 组装 docvalue_fields 列表
build_fields() {
  local list="\"$CONV_FIELD\",\"$SEQ_FIELD\",\"$CONTENT_FIELD\""
  if [[ -n "$EXTRA_FIELDS" ]]; then
    local f
    IFS=',' read -ra arr <<< "$EXTRA_FIELDS"
    for f in "${arr[@]}"; do
      f="$(echo "$f" | tr -d ' ')"
      [[ -n "$f" ]] && list="$list,\"$f\""
    done
  fi
  echo "[$list]"
}
FIELDS="$(build_fields)"

# 组装 query：term 命中用户字段，可选叠加会话过滤
if [[ -n "$CONV" ]]; then
  QUERY="{\"bool\":{\"filter\":[{\"term\":{\"$USER_FIELD\":$REV}},{\"term\":{\"$CONV_FIELD\":\"$CONV\"}}]}}"
else
  QUERY="{\"term\":{\"$USER_FIELD\":$REV}}"
fi

# curl 鉴权走 -K stdin，避免用户名密码进 ps / 命令历史
curl_es() {  # $1=path  $2=body
  printf 'user = "%s:%s"\n' "$LINDORM_USER" "$LINDORM_PASSWORD" | \
    curl -sS -m 120 -K - "$BASE/$1" -H 'Content-Type: application/json' -d "$2"
}

echo "索引: $IDX" >&2
echo "$USER_FIELD(用于匹配) = $REV$([[ $REVERSED -eq 0 ]] && echo "  (原始 UID $UID_IN 反转而来)")" >&2
[[ -n "$CONV" ]] && echo "限定会话: $CONV" >&2

case "$MODE" in
  count)
    body="{\"track_total_hits\":true,\"size\":0,\"query\":$QUERY}"
    resp="$(curl_es "$IDX/_search" "$body")"
    if [[ $HAVE_JQ -eq 1 ]]; then
      echo "命中总数: $(echo "$resp" | jq '.hits.total.value')"
    else
      echo "$resp"
    fi
    ;;

  page)
    body="{\"size\":$SIZE,\"track_total_hits\":true,\"query\":$QUERY,\"docvalue_fields\":$FIELDS,\"sort\":[{\"$CONV_FIELD\":\"asc\"},{\"$SEQ_FIELD\":\"asc\"}]}"
    resp="$(curl_es "$IDX/_search" "$body")"
    if [[ $RAW -eq 1 || $HAVE_JQ -eq 0 ]]; then
      echo "$resp"
    else
      echo "命中总数: $(echo "$resp" | jq '.hits.total.value')" >&2
      echo "$resp" | jq -r --arg cf "$CONV_FIELD" --arg sf "$SEQ_FIELD" --arg ctf "$CONTENT_FIELD" \
        '.hits.hits[] | .fields | "── \($cf)=\(.[$cf][0]) \($sf)=\(.[$sf][0])\n\(.[$ctf][0])\n"'
    fi
    ;;

  export)
    [[ $HAVE_JQ -eq 1 ]] || die "导出模式需要 jq"
    : > "$EXPORT_FILE"
    total=0; after=""
    while :; do
      if [[ -z "$after" ]]; then
        body="{\"size\":1000,\"query\":$QUERY,\"docvalue_fields\":$FIELDS,\"sort\":[{\"$CONV_FIELD\":\"asc\"},{\"$SEQ_FIELD\":\"asc\"}]}"
      else
        body="{\"size\":1000,\"query\":$QUERY,\"docvalue_fields\":$FIELDS,\"sort\":[{\"$CONV_FIELD\":\"asc\"},{\"$SEQ_FIELD\":\"asc\"}],\"search_after\":$after}"
      fi
      resp="$(curl_es "$IDX/_search" "$body")"
      n="$(echo "$resp" | jq '.hits.hits | length')"
      [[ "$n" -eq 0 ]] && break
      # 每条落一行 JSONL：摊平 fields（每个字段取数组首值）
      echo "$resp" | jq -c '.hits.hits[] | .fields | map_values(.[0])' >> "$EXPORT_FILE"
      total=$((total + n))
      after="$(echo "$resp" | jq -c '.hits.hits[-1].sort')"
      echo "  已导出 $total 条..." >&2
      [[ "$n" -lt 1000 ]] && break
    done
    echo "完成：$total 条 -> $EXPORT_FILE" >&2
    ;;
esac
