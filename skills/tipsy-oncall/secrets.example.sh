#!/usr/bin/env bash
# tipsy-oncall 所需凭证(示例)。
#
# 真实文件位于 ~/github/my_dot_files/secrets.sh —— skill 运行时会 `source` 它注入 env。
# install.sh 会自动把下面的 marker 块追加到你的 secrets.sh 末尾(值留空);
# 你只需要打开 secrets.sh 填实际值即可。
#
# 校验是否已生效:
#   source ~/github/my_dot_files/secrets.sh \
#     && echo "AK: ${ALIYUN_ACCESS_KEY_ID:0:6}..." \
#     && [ -n "$ALIYUN_ACCESS_KEY_SECRET" ] && echo "SK ok" \
#     && [ -n "$ALIYUN_REDIS_INSTANCE_ID_PROD" ] && echo "prod redis ok" \
#     && [ -n "$ALIYUN_ES_ENDPOINT_PROD" ] && echo "prod es ok" \
#     && [ -n "$TIPSY_MEMORY_URL_PROD" ] && echo "prod memory ok"
#
# ⚠️ 铁律:真实值绝不提交任何仓库、绝不 echo、绝不写 .env。

# ============================================================
# tipsy-oncall skill (auto-append by install.sh)
# ============================================================

# --- Aliyun 通用 AK/SK ---
# Redis RunCommand OpenAPI + ES(若走 SDK)+ 后续任何 aliyun-python-sdk 都会用到。
# 建议单独开一个 RAM 子账号,附 kvstore:RunCommand 只读策略。
# 阿里云控制台 → RAM → 用户 → 创建 AccessKey。
export ALIYUN_ACCESS_KEY_ID="LTAIxxxxxxxxxxxxxxxxxxxx"
export ALIYUN_ACCESS_KEY_SECRET="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Redis / ES 所在 region。tipsy 主 region:cn-hongkong;备:us-east-1。
export ALIYUN_REGION_ID="cn-hongkong"

# --- Redis 实例 ID ---
# 阿里云控制台 → 云数据库Redis → 实例列表 → 实例 ID 列(形如 r-xxxxxxxxxxxx)。
# 数据面走 RunCommand OpenAPI,**不需要 Redis 密码,也不需要 6379 白名单**。
export ALIYUN_REDIS_INSTANCE_ID_PROD="r-xxxxxxxxxxxxxxxx"
export ALIYUN_REDIS_INSTANCE_ID_TEST="r-yyyyyyyyyyyyyyyy"

# --- Elasticsearch endpoint + 认证 ---
# 阿里云 ES 是标准 Elasticsearch REST。
# 前置:控制台 → 网络与安全 → **打开公网访问 + 加你的出口 IP 白名单**。
# endpoint 形如 https://es-cn-xxxxxxxxxxxx.public.elasticsearch.aliyuncs.com:9200
export ALIYUN_ES_ENDPOINT_PROD="https://es-cn-xxxxxxxxxx.public.elasticsearch.aliyuncs.com:9200"
export ALIYUN_ES_ENDPOINT_TEST="https://es-cn-yyyyyyyyyy.public.elasticsearch.aliyuncs.com:9200"
export ALIYUN_ES_USERNAME="elastic"
export ALIYUN_ES_PASSWORD="xxxxxxxxxxxxxxxx"

# --- Tipsy memory 服务 host ---
# 内部 endpoint,无鉴权。绝不能对外暴露 —— 只在 skill 内部 curl 用。
export TIPSY_MEMORY_URL_PROD="https://tipsy-memory.infra.fantacy.live"
export TIPSY_MEMORY_URL_TEST="https://tipsy-memory-test.infra.fantacy.live"

# --- 阿里云 DMS 页面 URL(Chrome 兜底路径) ---
# 当 API 走不通(未开公网 / 未加白名单)时,skill 会打开这些 URL 让浏览器接管。
# 从阿里云 DMS 控制台 → 数据库列表 → 单击实例 → 复制 URL 栏(含 workspace + dbId)。
export ALIYUN_DMS_LINDORM_URL_PROD="https://dms.aliyun.com/?dbId=xxxxx"
export ALIYUN_DMS_LINDORM_URL_TEST="https://dms.aliyun.com/?dbId=yyyyy"
export ALIYUN_DMS_REDIS_URL_PROD="https://dms.aliyun.com/?dbId=zzzzz"
export ALIYUN_DMS_ES_URL_PROD="https://dms.aliyun.com/?dbId=wwwww"

# --- 内部页面入口 ---
# 401 重授权 / 手动查页面用。skill 不会自动打开,只在报告里给用户。
export TIPSY_BYTEBASE_URL="https://bytebase.infra.fantacy.live"
export TIPSY_METAMCP_URL="https://metamcp.fantacy.live"

# ============================================================
# end of tipsy-oncall skill
# ============================================================
