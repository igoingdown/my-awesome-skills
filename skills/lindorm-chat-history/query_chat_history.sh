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
#     --raw                    直接输出后端原始 JSON（不做 jq 美化）
#     --backend <name>         lindorm(默认，ES 直连) | tool-bridge(经 TB 网关走宽表 SQL 查询，含 sender_type)
#                              TB 后端下 --index 表示【宽表名】(见 secrets 里 LINDORM_TB_* 配置)，非 ES 索引全名
#     --secrets <path>         指定 secrets 文件，默认 ~/github/my_dot_files/secrets.sh
#   环境变量: SECRETS_FILE 同 --secrets；LINDORM_BACKEND 同 --backend
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
BACKEND="${LINDORM_BACKEND:-lindorm}"   # lindorm | tool-bridge
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
    --backend) BACKEND="${2:?}"; shift 2;;
    --secrets) SECRETS_FILE="${2:?}"; shift 2;;
    -h|--help) sed -n '2,36p' "$0"; exit 0;;
    -[0-9]*) [[ -z "$UID_IN" ]] && { UID_IN="$1"; shift; } || die "多余参数: $1";;  # 负数 UID（-开头但是数字）
    -*) die "未知选项: $1";;
    *) [[ -z "$UID_IN" ]] && UID_IN="$1" || die "多余参数: $1"; shift;;
  esac
done

[[ "$BACKEND" == "lindorm" || "$BACKEND" == "tool-bridge" ]] || die "未知 backend: $BACKEND（可用: lindorm | tool-bridge）"

[[ -n "$UID_IN" ]] || die "缺少 UID。用法: $0 <uid> [选项]，见 --help"
# UID 允许负号：宽表 rev_user_id 是 BIGINT，反转后可能是负值。
[[ "$UID_IN" =~ ^-?[0-9]+$ ]] || die "UID 必须是（可带负号的）十进制整数: $UID_IN"

# 凭据/配置：优先用已注入的 env，否则 source secrets 文件（只引用键名，不回显值）。
# 注意不能只看「连接凭据」在不在——索引名/工具路径等配置可能是后来才加进 secrets 的，
# 环境里有旧凭据不代表配置齐了。缺任何一项都触发 source。
need_source=0
if [[ "$BACKEND" == "lindorm" ]]; then
  [[ -z "${LINDORM_ENDPOINT_URL:-}" || -z "${LINDORM_USER:-}" || -z "${LINDORM_PASSWORD:-}" ]] && need_source=1
  [[ -z "$INDEX_OVERRIDE" && -z "${LINDORM_CHAT_INDEX:-}" ]] && need_source=1
else
  [[ -z "${TB_SK:-}" || -z "${TB_BASE_URL:-}" ]] && need_source=1
  [[ -z "${LINDORM_TB_REVID_TOOL:-}" || -z "${LINDORM_TB_COUNT_TOOL:-}" || -z "${LINDORM_TB_QUERY_TOOL:-}" ]] && need_source=1
fi
if [[ $need_source -eq 1 ]]; then
  [[ -f "$SECRETS_FILE" ]] || die "找不到 secrets 文件: $SECRETS_FILE（参考 secrets.example.sh）"
  set +u; # shellcheck disable=SC1090
  source "$SECRETS_FILE"; set -u
fi

# 索引名与字段名从 env 注入，带通用默认；真实内部命名放本地 secrets，不进仓库
IDX="${INDEX_OVERRIDE:-${LINDORM_CHAT_INDEX:-}}"
USER_FIELD="${LINDORM_USER_FIELD:-rev_user_id}"
CONV_FIELD="${LINDORM_CONV_FIELD:-conversation_id}"
SEQ_FIELD="${LINDORM_SEQ_FIELD:-sequence}"
CONTENT_FIELD="${LINDORM_CONTENT_FIELD:-content}"
# 额外要取的字段，逗号分隔，可选
EXTRA_FIELDS="${LINDORM_EXTRA_FIELDS:-}"

if [[ "$BACKEND" == "lindorm" ]]; then
  : "${LINDORM_ENDPOINT_URL:?secrets 缺少 LINDORM_ENDPOINT_URL}"
  : "${LINDORM_USER:?secrets 缺少 LINDORM_USER}"
  : "${LINDORM_PASSWORD:?secrets 缺少 LINDORM_PASSWORD}"
  [[ -n "$IDX" ]] || die "secrets 缺少 LINDORM_CHAT_INDEX（索引名），或用 --index 指定"
else
  # tool-bridge 后端：凭据 + 工具名映射。真实节点路径放本地 secrets（不进仓库），
  # 用 tb_probe.sh 实测你网关上的真实工具名后填 LINDORM_TB_* 变量，见 secrets.example.sh。
  : "${TB_BASE_URL:?secrets 缺少 TB_BASE_URL（你的 tool-bridge 网关地址，放本地 secrets）}"
  : "${TB_SK:?secrets 缺少 TB_SK：先浏览器登录 \$TB_BASE_URL/login 拿 key，见 TUTORIAL.md}"
  TB_REVID_TOOL="${LINDORM_TB_REVID_TOOL:?secrets 缺少 LINDORM_TB_REVID_TOOL（你网关上 rev_user_id 检索工具的节点路径）}"
  TB_COUNT_TOOL="${LINDORM_TB_COUNT_TOOL:?secrets 缺少 LINDORM_TB_COUNT_TOOL（你网关上 count 工具的节点路径）}"
fi

command -v curl >/dev/null || die "需要 curl"
HAVE_JQ=0; command -v jq >/dev/null && HAVE_JQ=1

if [[ "$REVERSED" -eq 1 ]]; then
  REV="$UID_IN"
elif [[ "$UID_IN" == -* ]]; then
  # 负值不可能是某个 user_id 的十进制反转结果，它本身就是存储侧的 rev_user_id。
  die "UID 是负数（$UID_IN）——这已是存储侧 rev_user_id，请加 --reversed 跳过反转。"
else
  rev_dec="$(printf '%s' "$UID_IN" | rev)"   # 十进制字符串整体倒序
  # 存储侧存的是 int64(ReverseUint64(uid))：反转后的十进制若 > INT64_MAX（约 7.7% 的 UID），
  # 要按有符号 64 位补码回绕成负 BIGINT。bash 是 64 位有符号运算，$(( 10# )) 正好复刻这个回绕
  # （同时去掉反转产生的前导零）。不回绕的话 rev_user_id 为 BIGINT 的宽表会报
  # "Can't convert to BIGINT. Overflow"，被 -e/tb_call 吞成失败(n=-1)，整批悄悄漏掉这些用户。
  REV=$(( 10#$rev_dec ))
  [[ "$REV" == -* ]] && echo "[rev 溢出回绕] $rev_dec → $REV（超出 INT64_MAX，按有符号 int64 补码回绕）" >&2
fi

if [[ "$BACKEND" == "tool-bridge" ]]; then
  # ── tool-bridge 后端（两套引擎，别混）─────────────────
  #   搜索侧计数/聚合工具（ES）：只 count/聚合，禁正文，且索引【无 sender_type】字段。
  #   宽表侧 SQL 查询工具：可 SELECT content + sender_type 真值(1/2)，是拿原文的正路。
  # 因此：--count 走计数工具（快）；page/export（要原文+角色）走宽表 SQL 查询工具。
  # 坑（都踩过，代码已应对）：
  #   1) 单 MCP 容器会【偶发串台】——返回别的请求结果。每次必须核对回显 SQL==发出的 SQL，不符即重试。
  #   2) 宽表 SQL 查询返回 markdown 表格且【只展示前 50 行】，故分页 LIMIT<=50 + OFFSET，逐页拼。
  #   3) 宽表引擎 9 秒硬超时——只做带 WHERE rev_user_id 的分区点查，禁全表 GROUP BY/DISTINCT/无过滤 ORDER BY。
  #   4) 网关侧 export_result 落容器侧、拿不回本机，故不用它；直接解析返回的表格落本机 JSONL。
  TBC="bash $HERE/tb_call.sh"
  TB_QUERY_TOOL="${LINDORM_TB_QUERY_TOOL:?secrets 缺少 LINDORM_TB_QUERY_TOOL（你网关上宽表 SQL 查询工具的节点路径）}"
  # 宽表名（非搜索索引全名）：由 --index 或 LINDORM_TB_TABLE 指定；默认取 env LINDORM_TB_DEFAULT_TABLE。
  # 带 conversation/rich 特征的表名会触发列集差异（见下），命名以你自己的宽表为准。
  TB_TABLE="${INDEX_OVERRIDE:-${LINDORM_TB_TABLE:-${LINDORM_TB_DEFAULT_TABLE:?secrets 缺少 LINDORM_TB_DEFAULT_TABLE（默认宽表名），或用 --index 指定}}}"
  PAGE_MAX=50; RETRY=3
  # 用户字段：*_rich 表用 user_id 原值，其余用 rev_user_id（REV）
  if [[ "$TB_TABLE" == *rich* ]]; then UF="user_id"; UV="$UID_IN"; else UF="$USER_FIELD"; UV="$REV"; fi
  echo "[backend=tool-bridge] table=$TB_TABLE  $UF=$UV  mode=$MODE" >&2

  if [[ "$MODE" == "count" ]]; then
    # count 用宽表点查（分区内 COUNT，安全）；也可用搜索侧计数工具，但这里统一走宽表口径。
    sql="SELECT COUNT(*) AS c FROM $TB_TABLE WHERE $UF=$UV"
    for t in $(seq 1 $RETRY); do
      resp="$($TBC call "$TB_QUERY_TOOL" "{\"sql\":\"$sql\"}" 2>&1 || true)"
      echo "$resp" | command grep -qF "$sql" && break
      echo "  [count 回显不符/失败，重试 $t/$RETRY]" >&2; sleep 1
    done
    echo "$resp"
    exit 0
  fi

  # page / export：宽表 SQL 查询分页取原文 + sender_type，落本机
  # 排序用 sequence DESC 取“近期”；SELECT 列顺序与 _parse_tb_lindorm.py 约定一致。
  cols="${LINDORM_TB_COLS:-character_id,sequence,sender_type,timestamp,content}"
  [[ "$TB_TABLE" == *conversation* || "$TB_TABLE" == *rich* ]] && cols="conversation_id,$cols"
  want=$SIZE; [[ "$MODE" == "export" ]] && want=100000
  OUT="${EXPORT_FILE:-/dev/stdout}"
  [[ "$MODE" == "export" ]] && : > "$OUT"
  tmp="$(mktemp)"; : > "$tmp"
  off=0; got=0
  while [[ $off -lt $want ]]; do
    lim=$PAGE_MAX; [[ $((want-off)) -lt $lim ]] && lim=$((want-off))
    sql="SELECT $cols FROM $TB_TABLE WHERE $UF=$UV ORDER BY sequence DESC LIMIT $lim OFFSET $off"
    n=""
    for t in $(seq 1 $RETRY); do
      resp="$($TBC call "$TB_QUERY_TOOL" "{\"sql\":\"$sql\"}" 2>&1 || true)"
      n="$(printf '%s' "$resp" | python3 "$HERE/_parse_tb_lindorm.py" "$sql" "$tmp")"
      [[ "$n" =~ ^[0-9]+$ ]] && break
      echo "  [off=$off 串台/解析失败(n=$n)，重试 $t/$RETRY]" >&2; sleep 1
    done
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "  [off=$off 连续失败，停止]" >&2; break; }
    got=$((got+n)); echo "  off=$off → $n 条（累计 $got）" >&2
    off=$((off+lim))
    [[ "$n" -lt "$lim" ]] && break   # 末页
    sleep 0.5                          # 分页间限速，护 devbox
  done
  if [[ "$MODE" == "export" ]]; then
    cat "$tmp" >> "$OUT"; echo "完成：$got 条 -> $OUT" >&2
  else
    if [[ $HAVE_JQ -eq 1 && $RAW -eq 0 ]]; then
      jq -r '"── seq=\(.sequence) sender_type=\(.sender_type)\n\(.content)\n"' "$tmp"
    else
      cat "$tmp"
    fi
    echo "命中 $got 条（table=$TB_TABLE）" >&2
  fi
  rm -f "$tmp"
  exit 0
fi

# ── lindorm 直连后端（默认）───────────────────────────────────────────
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
