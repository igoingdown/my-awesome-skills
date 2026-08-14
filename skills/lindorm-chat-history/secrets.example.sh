#!/usr/bin/env bash
# lindorm-chat-history 所需凭证与配置（示例）。
#
# 真实文件位于 ~/github/my_dot_files/secrets.sh —— 脚本运行时会 `source` 它注入 env
# （可用环境变量 SECRETS_FILE 或 --secrets 改路径）。把下面内容加进你的 secrets.sh，
# ⚠️ 真实用户名/密码/索引名绝不提交进任何仓库。
#
# 注意：这是 LindormSearch(ES 兼容) 的接入地址，不是 LindormTable SQL 地址。
#      地址里通常带 proxy-search 和端口 30070。

# --- 必填：连接凭据 ---
export LINDORM_USER="your-username-here"
export LINDORM_PASSWORD="your-password-here"
export LINDORM_ENDPOINT_URL="http://ld-xxxxxxxx-proxy-search-public.lindorm.rds.aliyuncs.com:30070"

# --- 必填：聊天记录索引名（也可用脚本 --index 覆盖）---
export LINDORM_CHAT_INDEX="your_chat_history_index_name"

# --- 可选：字段名映射，按你的索引 mapping 调整 ---
# 用户 ID 字段。若索引把 UID 反转后存储，这里填反转字段(如 rev_user_id)，脚本默认会反转输入的 UID。
# export LINDORM_USER_FIELD="rev_user_id"
# export LINDORM_CONV_FIELD="conversation_id"
# export LINDORM_SEQ_FIELD="sequence"
# export LINDORM_CONTENT_FIELD="content"

# --- 可选：额外要取的字段，逗号分隔 ---
# export LINDORM_EXTRA_FIELDS="character_id,update_version_l"

# ============================================================================
# 可选：tool-bridge 网关后端（--backend tool-bridge）
# ----------------------------------------------------------------------------
# lindorm 直连是默认后端，以下仅在你想经自己的 tool-bridge 网关查询时才需要。
# 拿 SK：浏览器开 $TB_BASE_URL/login 走 OAuth，回调页一次性显示 SK+BaseURL。
# 详见本 skill 目录的 TUTORIAL.md。
# 工具节点路径因网关部署而异——先用 tb_probe.sh 实测你网关上的真实工具名，再填下面几项。
# ============================================================================
# export TB_BASE_URL="https://your-tool-bridge.example.com"
# export TB_SK=""   # 登录换取，有有效期；再次登录会 rotate 旧 key；勿提交进任何仓库

# --- 可选：TB 上聊天工具的节点路径（用 tb_probe.sh 实测后填你网关上的真实值）---
# export LINDORM_TB_REVID_TOOL="<your-gateway>/<rev_user_id 检索工具节点路径>"
# export LINDORM_TB_COUNT_TOOL="<your-gateway>/<count 工具节点路径>"
# export LINDORM_TB_QUERY_TOOL="<your-gateway>/<宽表 SQL 查询工具节点路径>"
# export LINDORM_TB_DEFAULT_TABLE="<你的默认宽表名>"   # 也可用 --index 覆盖
