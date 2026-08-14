#!/usr/bin/env bash
# 查某人近 N 天需要关注的 Meego 需求和缺陷（参与人含此人 + 近 N 天有更新）。
#
# 用法:
#   bash my_focus.sh "<中文姓名>" [天数]        # 默认 7 天
#   bash my_focus.sh --user-key <key> [天数]   # 已知 user_key 时跳过反查
# 配置: MEEGO_PROJECT_KEY 必填（secrets.sh 或 env）；TB_BASE_URL/TB_SK 由 tb_call.sh 读取。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="bash $HERE/../tb_call.sh"
PARSE="python3 $HERE/parse_meego.py"
SECRETS_FILE="${SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
die(){ echo "ERROR: $*" >&2; exit 1; }

NAME=""; UKEY=""; DAYS=7
if [[ "${1:-}" == "--user-key" ]]; then UKEY="${2:?}"; DAYS="${3:-7}"; else NAME="${1:?用法: my_focus.sh <姓名> [天数]}"; DAYS="${2:-7}"; fi

[[ -z "${MEEGO_PROJECT_KEY:-}" && -f "$SECRETS_FILE" ]] && { set +u; source "$SECRETS_FILE"; set -u; }
: "${MEEGO_PROJECT_KEY:?缺 MEEGO_PROJECT_KEY（见 secrets.example.sh）}"
PK="$MEEGO_PROJECT_KEY"

mkargs(){ python3 -c 'import json,sys; print(json.dumps({"project_key":sys.argv[1],"mql":sys.argv[2]}))' "$PK" "$1"; }

# 1) 反查 user_key（注意：current_login_user() 是固定挂载身份，不是"你"）
if [[ -z "$UKEY" ]]; then
  resp=$($TB call mcp/meego/search_user_info "{\"project_key\":\"$PK\",\"user_keys\":[\"$NAME\"]}" 2>&1)
  UKEY=$(echo "$resp" | command grep -oE '\\"user_key\\":\\"[0-9]+' | head -1 | command grep -oE '[0-9]+' || true)
  [[ -n "$UKEY" ]] || die "反查不到 $NAME 的 user_key。原始返回: $(echo "$resp" | head -c 200)"
  echo "[$NAME → user_key=$UKEY]" >&2
fi

echo "===== 需求：近 ${DAYS} 天有更新 + 参与人含目标用户 ====="
$TB call mcp/meego/search_by_mql "$(mkargs "SELECT \`名称\`, \`状态\`, \`更新时间\` FROM \`$PK\`.\`需求\` WHERE RELATIVE_DATETIME_BETWEEN(\`更新时间\`, 'past', '${DAYS}d') AND array_contains(all_participate_persons(), '<id:$UKEY>') ORDER BY \`更新时间\` DESC LIMIT 50")" | $PARSE rows

echo
echo "===== 缺陷：近 ${DAYS} 天有更新 + 参与人含目标用户 ====="
# 注意：缺陷标题字段是 缺陷名称（不是 名称）；状态在 MQL 里不认，用 get_workitem_brief 单独查
$TB call mcp/meego/search_by_mql "$(mkargs "SELECT \`缺陷名称\`, \`优先级\`, \`影响程度\`, \`更新时间\` FROM \`$PK\`.\`缺陷\` WHERE RELATIVE_DATETIME_BETWEEN(\`更新时间\`, 'past', '${DAYS}d') AND array_contains(all_participate_persons(), '<id:$UKEY>') ORDER BY \`更新时间\` DESC LIMIT 50")" | $PARSE rows

echo
echo "（缺陷的状态/ID/负责人：bash $HERE/../tb_call.sh call mcp/meego/get_workitem_brief '{\"project_key\":\"$PK\",\"work_item_type_key\":\"issue\",\"name\":\"<标题>\"}'）" >&2
