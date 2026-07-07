#!/bin/bash
# Vultr 账户余额检查脚本
# 查询账户余额和当月待扣费用，可选通过飞书发送通知

set -e

# ==================== 凭证：统一走 secrets.sh ====================
# 环境变量已设置则直接用；否则从个人凭证文件注入（不进任何版本库）。
SECRETS="${SECRETS_FILE:-$HOME/github/my_dot_files/secrets.sh}"
if [ -z "${VULTR_API_KEY:-}" ] && [ -f "$SECRETS" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS"
fi
# ==================================================================

# 检查必需的环境变量
if [ -z "${VULTR_API_KEY:-}" ]; then
    echo "❌ Error: VULTR_API_KEY is not set"
    echo "请在 $SECRETS 中加入：export VULTR_API_KEY=\"...\"（参考 secrets.example.sh）"
    exit 1
fi

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "❌ Error: jq is not installed"
    echo "Please run: bash install.sh"
    exit 1
fi

# 配置默认值
WORKSPACE="${VULTR_WORKSPACE_PATH/#\~/$HOME}"
WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
FEISHU_RECEIVER_ID="${FEISHU_RECEIVER_ID:-}"

# 调用 Vultr API
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/account)
CURL_EXIT=$?
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')

if [ $CURL_EXIT -ne 0 ]; then
    echo "❌ Error: curl 请求失败 (exit=$CURL_EXIT)"
    exit 1
fi

# 检查 API 错误（HTTP 非 2xx 或返回体包含 error 字段）
API_ERROR=$(echo "$RESPONSE" | jq -r '.error // empty' 2>/dev/null)
if [ "$HTTP_CODE" != "200" ] || [ -n "$API_ERROR" ]; then
    echo "❌ Vultr API 调用失败 (HTTP $HTTP_CODE)"
    [ -n "$API_ERROR" ] && echo "   原因: $API_ERROR"
    echo "   原始响应: $RESPONSE"
    exit 1
fi

# 提取数据
BALANCE=$(echo "$RESPONSE" | jq -r '.account.balance // "未知"')
PENDING_CHARGES=$(echo "$RESPONSE" | jq -r '.account.pending_charges // "未知"')

# 获取当前时间
NOW=$(date '+%Y-%m-%d %H:%M:%S')

# 构建消息
MESSAGE="⏰ Vultr 账户状态更新（${NOW}）

💰 账户余额: ${BALANCE} 美元
📊 待扣费用: ${PENDING_CHARGES} 美元"

# 输出消息
echo ""
echo "$MESSAGE"
echo ""

# 记录到日志文件
mkdir -p "$WORKSPACE"
LOG_FILE="$WORKSPACE/vultr_balance.log"
echo "$MESSAGE" >> "$LOG_FILE"
echo "✅ 已记录到日志: $LOG_FILE"

# 通过飞书发送消息（如果配置了）：优先 openclaw，缺失则回退 lark-cli
if [ -n "$FEISHU_RECEIVER_ID" ]; then
    OPENCLAW_PATH=$(which openclaw 2>/dev/null || echo "")
    LARK_PATH="${LARK_CLI:-$(which lark-cli 2>/dev/null || echo "")}"

    if [ -n "$OPENCLAW_PATH" ]; then
        echo ""
        echo "📤 正在通过飞书发送消息（openclaw）..."
        "$OPENCLAW_PATH" message send \
            --channel feishu \
            --target "$FEISHU_RECEIVER_ID" \
            --message "$MESSAGE"

        if [ $? -eq 0 ]; then
            echo "✅ 飞书消息发送成功！"
        else
            echo "⚠️  飞书消息发送失败"
        fi
    elif [ -n "$LARK_PATH" ]; then
        echo ""
        echo "📤 正在通过飞书发送消息（lark-cli）..."
        if "$LARK_PATH" im +messages-send --user-id "$FEISHU_RECEIVER_ID" --as user --text "$MESSAGE" >/dev/null 2>&1; then
            echo "✅ 飞书消息发送成功！"
        else
            echo "⚠️  飞书消息发送失败（lark-cli token 可能需重新授权：lark-cli auth login）"
        fi
    else
        echo ""
        echo "⚠️  未找到 openclaw / lark-cli 命令，跳过飞书消息发送"
    fi
fi
