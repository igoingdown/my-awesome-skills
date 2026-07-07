#!/usr/bin/env bash
# openrouter-balance 所需凭证（示例）。
#
# 真实文件位于 ~/github/my_dot_files/secrets.sh —— 脚本运行时会 `source` 它注入 env
# （可用环境变量 SECRETS_FILE 改路径）。把下面内容加进你的 secrets.sh，
# ⚠️ 真实 Key 绝不提交进任何仓库。
#
# OpenRouter API Key：https://openrouter.ai/settings/keys
# 飞书应用凭证：https://open.feishu.cn/app（应用详情页「凭证与基础信息」）

export OPENROUTER_API_KEY="sk-or-v1-xxxx"
export FEISHU_APP_ID="cli_xxxx"
export FEISHU_APP_SECRET="xxxx"
export FEISHU_RECEIVER_OPEN_ID="ou_xxxxxxxxxxxxxxxx"
