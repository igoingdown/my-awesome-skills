#!/usr/bin/env bash
# redis-cmd.sh — 阿里云 R-KVStore RunCommand OpenAPI 只读封装
#
# 走公网 OpenAPI 网关(r-kvstore.aliyuncs.com),不需要 Redis 密码,不需要开 6379。
# AK/SK 从 secrets.sh 注入,region/实例 ID 从 env 变量读。
#
# 只放行只读命令(白名单),黑名单命令直接拒绝。集群版跨 slot 命令(KEYS *)会失败。
# 大 hash 用 HSCAN 分片,不要一次 HGETALL 巨型 key。
#
# 用法示例:
#   bash redis-cmd.sh prod GET session:12345
#   bash redis-cmd.sh test HGETALL character:abc
#   bash redis-cmd.sh prod TTL rate_limit:user:999
#   bash redis-cmd.sh prod SCAN 0 MATCH 'pending:*' COUNT 100

set -euo pipefail

# 凭证统一从仓库外 secrets 文件注入(可用 TIPSY_ONCALL_SECRETS_FILE 覆盖路径)
SECRETS_FILE="${TIPSY_ONCALL_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$SECRETS_FILE"
fi

# ---- 用法 ----
usage() {
  cat <<'EOF'
用法: redis-cmd.sh <env> <cmd> [args...]

参数:
  env     prod | test        —— 决定用哪个实例(_PROD/_TEST 变量)
  cmd     Redis 命令(只读白名单):
            GET | HGETALL | HKEYS | HGET | TYPE | TTL | EXISTS | STRLEN
            LLEN | LRANGE | SMEMBERS | SCARD | HSCAN | SSCAN | ZSCAN | SCAN
            ZRANGE | ZRANGEBYSCORE | ZCARD | ZSCORE
            KEYS(慎用,集群版跨 slot 会 fail;单机小库才用)
            DBSIZE | INFO
  args    命令参数,原样拼接

前置:
  1. source ~/github/my_dot_files/secrets.sh 已注入 ALIYUN_ACCESS_KEY_ID / SECRET
  2. secrets.sh 已配置 ALIYUN_REDIS_INSTANCE_ID_{PROD,TEST}
  3. RAM 子账号权限包含 kvstore:RunCommand
     (AliyunKvstoreReadOnlyAccess 不够,需要 FullAccess 或自定义策略)

依赖:
  python3(内置 hmac/hashlib/urllib,不需 pip 装包)

Chrome 兜底(API 走不通时,如白名单未开或 RAM 不够权限):
  echo "打开 $ALIYUN_DMS_REDIS_URL_PROD,用 nimbalyst-browser 打命令 tab"
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" || $# -lt 2 ]]; then
  usage
  exit 0
fi

# ---- 校验入参 ----
env_arg="$1"; shift
cmd_raw="$1"; shift
cmd="${cmd_raw^^}"  # 大写归一

# 只读白名单
allow_cmds=(GET HGETALL HKEYS HGET TYPE TTL EXISTS STRLEN LLEN LRANGE SMEMBERS SCARD HSCAN SSCAN ZSCAN SCAN ZRANGE ZRANGEBYSCORE ZCARD ZSCORE KEYS DBSIZE INFO)
# 黑名单(即使被白名单覆盖也拒绝)
deny_cmds=(FLUSHALL FLUSHDB CONFIG DEBUG SHUTDOWN SLAVEOF REPLICAOF MIGRATE CLIENT SCRIPT EVAL EVALSHA)

for d in "${deny_cmds[@]}"; do
  if [[ "$cmd" == "$d" ]]; then
    echo "[error] 命令 $cmd 在黑名单,禁止执行" >&2
    exit 2
  fi
done

allowed=0
for a in "${allow_cmds[@]}"; do
  if [[ "$cmd" == "$a" ]]; then allowed=1; break; fi
done
if [[ $allowed -eq 0 ]]; then
  echo "[error] 命令 $cmd 不在只读白名单;若确认要跑,加到 allow_cmds 列表" >&2
  exit 3
fi

# ---- 选择实例 ----
case "$env_arg" in
  prod) instance_id="${ALIYUN_REDIS_INSTANCE_ID_PROD:-}" ;;
  test) instance_id="${ALIYUN_REDIS_INSTANCE_ID_TEST:-}" ;;
  *)    echo "[error] env 必须是 prod 或 test,收到:$env_arg" >&2; exit 4 ;;
esac

: "${instance_id:?ALIYUN_REDIS_INSTANCE_ID_${env_arg^^} 未注入,请填 secrets.sh}"
: "${ALIYUN_ACCESS_KEY_ID:?ALIYUN_ACCESS_KEY_ID 未注入}"
: "${ALIYUN_ACCESS_KEY_SECRET:?ALIYUN_ACCESS_KEY_SECRET 未注入}"
region="${ALIYUN_REGION_ID:-cn-hongkong}"

# ---- 依赖检测 ----
if ! command -v python3 &>/dev/null; then
  echo "[error] 缺 python3。brew install python3" >&2
  exit 5
fi

# ---- 组装 args ----
args_str="$*"

# ---- 调 OpenAPI(python3 内置 urllib + hmac) ----
python3 <<PYEOF
import os, sys, time, uuid, hmac, hashlib, base64, urllib.parse, urllib.request, json

ak_id = os.environ["ALIYUN_ACCESS_KEY_ID"]
ak_sec = os.environ["ALIYUN_ACCESS_KEY_SECRET"]
region = "${region}"
instance_id = "${instance_id}"
cmd = "${cmd}"
args = """${args_str}""".strip()

params = {
    "Action": "RunCommand",
    "Version": "2015-01-01",
    "Format": "JSON",
    "SignatureMethod": "HMAC-SHA1",
    "SignatureNonce": uuid.uuid4().hex,
    "SignatureVersion": "1.0",
    "AccessKeyId": ak_id,
    "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "RegionId": region,
    "InstanceId": instance_id,
    "Command": cmd,
}
if args:
    params["ArgV"] = args

def rfc3986(s):
    return urllib.parse.quote(str(s), safe="~")

sorted_params = sorted(params.items())
canonical = "&".join(f"{rfc3986(k)}={rfc3986(v)}" for k, v in sorted_params)
string_to_sign = "GET&" + rfc3986("/") + "&" + rfc3986(canonical)
signing_key = (ak_sec + "&").encode("utf-8")
signature = base64.b64encode(hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha1).digest()).decode()
params["Signature"] = signature

url = "https://r-kvstore.aliyuncs.com/?" + urllib.parse.urlencode(params)
try:
    with urllib.request.urlopen(url, timeout=15) as resp:
        body = resp.read().decode("utf-8")
        try:
            print(json.dumps(json.loads(body), ensure_ascii=False, indent=2))
        except Exception:
            print(body)
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8", "replace")
    print(f"[HTTP {e.code}] {body}", file=sys.stderr)
    # 常见:白名单未开或 RAM 权限不足 → 提示走 Chrome 兜底
    if e.code in (400, 403):
        print("", file=sys.stderr)
        print("兜底方案:打开 \$ALIYUN_DMS_REDIS_URL_${env_arg^^},用 nimbalyst-browser 走 DMS 页面查询", file=sys.stderr)
    sys.exit(6)
except Exception as e:
    print(f"[error] {e}", file=sys.stderr)
    sys.exit(7)
PYEOF
