#!/bin/bash
# Vultr 账户余额检查脚本
# 查询账户余额和当月待扣费用，可选通过飞书发送通知

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================== 加载 .env 文件 ====================
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: .env file not found at $ENV_FILE"
    echo "Please copy .env.example to .env and fill in your credentials"
    exit 1
fi

# 读取 .env 文件中的变量
while IFS='=' read -r key value; do
    # 跳过空行和注释
    if [[ -n "$key" && ! "$key" =~ ^[[:space:]]*# ]]; then
        # 去除前后空格和引号
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs | sed 's/^["'\'']*//;s/["'\'']*$//')
        export "$key"="$value"
    fi
done < "$ENV_FILE"
# =========================================================

# 检查必需的环境变量
if [ -z "$VULTR_API_KEY" ]; then
    echo "❌ Error: VULTR_API_KEY is not set in .env"
    exit 1
fi

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "❌ Error: jq is not installed"
    echo "Please run: bash install.sh"
    exit 1
fi

# 配置默认值
WORKSPACE="${VULTR_WORKSPACE_PATH:-$HOME/.openclaw/workspace}"
FEISHU_RECEIVER_ID="${FEISHU_RECEIVER_ID:-}"

# 调用 Vultr API
RESPONSE=$(curl -s -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/account)

# 检查 curl 是否成功
if [ $? -ne 0 ]; then
    echo "❌ Error: API request failed"
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

# 通过飞书发送消息（如果配置了）
if [ -n "$FEISHU_RECEIVER_ID" ]; then
    # 动态获取 openclaw 路径
    OPENCLAW_PATH=$(which openclaw 2>/dev/null || echo "")

    if [ -n "$OPENCLAW_PATH" ]; then
        echo ""
        echo "📤 正在通过飞书发送消息..."
        "$OPENCLAW_PATH" message send \
            --channel feishu \
            --target "$FEISHU_RECEIVER_ID" \
            --message "$MESSAGE"

        if [ $? -eq 0 ]; then
            echo "✅ 飞书消息发送成功！"
        else
            echo "⚠️  飞书消息发送失败"
        fi
    else
        echo ""
        echo "⚠️  未找到 openclaw 命令，跳过飞书消息发送"
    fi
fi
