#!/bin/bash
# new-api / one-api 系网关：当日 LLM 用量查询 + 飞书私聊推送。
# 依赖：curl、python3、lark-cli（user token 已授权）。
# 配置：统一放在 secrets.sh（个人凭证文件，不进任何版本库），本脚本 source 后使用：
#   NEW_API_BASE_URL        new-api 实例地址
#   NEW_API_ACCESS_TOKEN    系统访问令牌（个人设置页生成）
#   NEW_API_USER_ID         平台用户 id（/api/user/self 的 data.id）
#   NEWAPI_REPORT_RECEIVER  飞书接收人 open_id
#   NEWAPI_QUOTA_PER_UNIT   可选，quota→$1 换算率，默认 500000（/api/status 的 quota_per_unit）
set -uo pipefail

SECRETS="${NEWAPI_SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
# shellcheck disable=SC1090
[ -f "$SECRETS" ] && source "$SECRETS"

: "${NEW_API_BASE_URL:?缺少 NEW_API_BASE_URL，请在 secrets.sh 中配置}"
: "${NEW_API_ACCESS_TOKEN:?缺少 NEW_API_ACCESS_TOKEN，请在 secrets.sh 中配置}"
: "${NEW_API_USER_ID:?缺少 NEW_API_USER_ID，请在 secrets.sh 中配置}"
: "${NEWAPI_REPORT_RECEIVER:?缺少 NEWAPI_REPORT_RECEIVER，请在 secrets.sh 中配置}"
QUOTA_PER_UNIT="${NEWAPI_QUOTA_PER_UNIT:-500000}"

# lark-cli 是 node 程序：优先 PATH；再补几个常见安装位置（macOS nvm/homebrew、Linux linuxbrew）。
# ⚠️ 只追加不覆盖——覆盖会把 Linux 上 node/lark-cli 所在目录冲掉。
export PATH="$PATH:$HOME/.nvm/versions/node/v24.15.0/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin"
LARK="${LARK_CLI:-$(command -v lark-cli || true)}"
if [ -z "$LARK" ] || [ ! -x "$LARK" ]; then
  echo "找不到 lark-cli，请安装或在 secrets.sh 中 export LARK_CLI=/path/to/lark-cli" >&2
  exit 1
fi

# 推送降噪状态：记录上次推送的指纹，内容无变化则跳过
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/newapi-usage"
STATE_FILE="$STATE_DIR/last_push"
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 今日 0 点：BSD date（macOS）优先，失败回退 GNU date（Linux）
START=$(date -v0H -v0M -v0S +%s 2>/dev/null || date -d 'today 00:00:00' +%s)
NOW=$(date +%s)
TODAY=$(date +%Y-%m-%d)

USAGE_JSON=$(curl -s -m 30 \
  "$NEW_API_BASE_URL/api/data/self?start_timestamp=$START&end_timestamp=$NOW&default_time=hour" \
  -H "Authorization: Bearer $NEW_API_ACCESS_TOKEN" \
  -H "New-Api-User: $NEW_API_USER_ID")
USER_JSON=$(curl -s -m 30 \
  "$NEW_API_BASE_URL/api/user/self" \
  -H "Authorization: Bearer $NEW_API_ACCESS_TOKEN" \
  -H "New-Api-User: $NEW_API_USER_ID")

export USAGE_JSON USER_JSON QUOTA_PER_UNIT
# 输出协议：STATUS|FINGERPRINT|BODY（FINGERPRINT 用于降噪比对）
MSG=$(python3 <<'PY'
import hashlib, json, os, sys
from datetime import datetime

QUOTA_PER_UNIT = int(os.environ["QUOTA_PER_UNIT"])

def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)

try:
    usage = json.loads(os.environ["USAGE_JSON"])
    user = json.loads(os.environ["USER_JSON"])
except (json.JSONDecodeError, KeyError) as e:
    print(f"ERROR|parse|接口返回无法解析: {e}")
    sys.exit(0)

if not usage.get("success"):
    msg = usage.get("message", "未知错误")
    print(f"ERROR|{hashlib.md5(msg.encode()).hexdigest()[:8]}|/api/data/self 调用失败: {msg}（access token 可能已失效，需重新生成并更新 secrets.sh）")
    sys.exit(0)

rows = usage.get("data") or []
if not rows:
    print("EMPTY||")
    sys.exit(0)

agg = {}
for r in rows:
    a = agg.setdefault(r["model_name"], {"quota": 0, "tokens": 0, "count": 0})
    a["quota"] += r.get("quota", 0)
    a["tokens"] += r.get("token_used", 0)
    a["count"] += r.get("count", 0)

lines = [f"📊 new-api 今日 LLM 用量（截至 {datetime.now():%m-%d %H:%M}）"]
total_usd = total_calls = total_quota = 0
for m, a in sorted(agg.items(), key=lambda x: -x[1]["quota"]):
    usd = a["quota"] / QUOTA_PER_UNIT
    total_usd += usd
    total_calls += a["count"]
    total_quota += a["quota"]
    lines.append(f"· {m}: ${usd:,.2f} | {fmt_tokens(a['tokens'])} tok | {a['count']} 次")
lines.append(f"—— 今日合计 ${total_usd:,.2f} · {total_calls} 次调用")

if user.get("success"):
    balance = user["data"].get("quota", 0) / QUOTA_PER_UNIT
    lines.append(f"💰 账户余额 ${balance:,.2f}")

# 指纹只含用量（quota+调用次数），有任何新调用即变化
print(f"OK|{total_quota}:{total_calls}|" + "\n".join(lines))
PY
)

STATUS="${MSG%%|*}"
REST="${MSG#*|}"
FINGERPRINT="${REST%%|*}"
BODY="${REST#*|}"

# 降噪：同日同指纹（用量无变化 / 同一错误）不重复推送
NEW_STATE="$TODAY:$STATUS:$FINGERPRINT"
LAST_STATE=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$STATUS" != "EMPTY" ] && [ "$NEW_STATE" = "$LAST_STATE" ]; then
  log "内容与上次推送一致（$NEW_STATE），跳过"
  exit 0
fi

case "$STATUS" in
  EMPTY)
    log "今日暂无用量，跳过推送"
    ;;
  ERROR)
    log "查询失败: $BODY"
    if "$LARK" im +messages-send --user-id "$NEWAPI_REPORT_RECEIVER" --as user \
      --text "⚠️ new-api 用量查询失败：$BODY" >/dev/null 2>&1; then
      echo "$NEW_STATE" >"$STATE_FILE"
    fi
    exit 1
    ;;
  OK)
    if "$LARK" im +messages-send --user-id "$NEWAPI_REPORT_RECEIVER" --as user --text "$BODY" >/dev/null 2>&1; then
      echo "$NEW_STATE" >"$STATE_FILE"
      log "推送成功"
    else
      log "飞书推送失败（lark-cli token 可能需重新授权：lark-cli auth login）"
      exit 1
    fi
    ;;
  *)
    log "未知输出: $MSG"
    exit 1
    ;;
esac
