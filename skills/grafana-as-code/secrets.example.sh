#!/usr/bin/env bash
# grafana-as-code 所需凭证（示例）。
#
# 真实文件位于 ~/github/my_dot_files/secrets.sh —— skill 运行时会 `source` 它来注入 env。
# 把下面两行加进你的 secrets.sh（⚠️ 真实 token 绝不提交进任何仓库）。
#
# 校验是否已生效：
#   source ~/github/my_dot_files/secrets.sh && echo "$GRAFANA_URL" && [ -n "$GRAFANA_TOKEN" ] && echo "token ok"

# 阿里云托管 Grafana 实例地址
export GRAFANA_URL="https://grafana-cn-c064otf0j01.grafana.aliyuncs.com"

# 服务账号 token（Grafana → 服务账号 → 赋 alert provisioning + dashboards:write → 生成）
# 绝不入库、绝不 echo、绝不写进 .env
export GRAFANA_TOKEN="glsa_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
