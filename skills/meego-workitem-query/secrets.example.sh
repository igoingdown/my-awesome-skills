#!/usr/bin/env bash
# meego-workitem-query 所需配置（示例）。
#
# 真实值加进 ~/github/my_dot_files/secrets.sh（或你自己的 secrets 文件，
# 运行时用 SECRETS_FILE 环境变量指过去）。⚠️ 真实 project_key / user_key /
# 姓名 / 租户域名绝不提交进任何仓库。

# --- tool-bridge 网关凭据（若已为 lindorm-chat-history 配过则复用，无需重复）---
# export TB_BASE_URL="https://<你的-tool-bridge-域名>"
# export TB_SK=""   # 浏览器开 $TB_BASE_URL/login 走企业飞书 OAuth 换取，90 天有效

# --- 默认 Meego 空间 ---
# project_key：Meego 空间的 key（形如 24 位十六进制），从空间设置或管理员处获取
export MEEGO_PROJECT_KEY="your-project-key-here"
# simple_name：Meego 网页 URL 路径里的空间短名（https://project.feishu.cn/<simple_name>/...）
export MEEGO_PROJECT_SIMPLE_NAME="your-space-simple-name"
