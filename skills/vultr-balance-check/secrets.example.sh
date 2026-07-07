#!/usr/bin/env bash
# vultr-balance-check 所需凭证（示例）。
#
# 真实文件位于 ~/github/my_dot_files/secrets.sh —— 脚本运行时会 `source` 它注入 env
# （可用环境变量 SECRETS_FILE 改路径）。把下面内容加进你的 secrets.sh，
# ⚠️ 真实 Key 绝不提交进任何仓库。
#
# 获取 API Key：https://my.vultr.com/settings/#settingsapi

export VULTR_API_KEY="your-api-key-here"

# 可选：日志输出路径，默认 ~/.openclaw/workspace
# export VULTR_WORKSPACE_PATH="$HOME/.openclaw/workspace"

# 可选：飞书接收者 open_id，不填则不发送飞书消息
# export FEISHU_RECEIVER_ID="ou_xxxxxxxxxxxxxxxx"
