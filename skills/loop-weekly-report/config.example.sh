# loop-weekly-report 配置示例
#
# 复制成本地真实配置（如 ~/.config/loop-weekly-report.sh），填好后由脚本 source。
# 真实值绝不要提交进这个公开仓库。

# 周报署名（出现在文档标题里）
export REPORT_OWNER="Your Name"

# 你的文档平台租户主机名（用于拼装文档链接，脱敏后不要硬编码到脚本里）
export DOC_TENANT_HOST="your-tenant.example.com"

# 周报汇总索引文档的 ID/token（新周报链接会插到它的锚点段落之后）
export WEEKLY_INDEX_DOC="your-index-doc-id"

# 索引文档里用来定位插入位置的锚点关键词（写在某个段落里，脚本按它找 block-id）
export WEEKLY_INDEX_ANCHOR_KW="[[ANCHOR:weekly-index]]"

# 通知命令：接收一个字符串参数，推送到你的即时通知渠道。留空则只写日志。
export NOTIFY_CMD="notify-send-im"

# 文档 CLI 命令名：用来创建/更新云文档的命令行工具（参考实现依赖一个私有 CLI）。
# 你需要换成自己的文档工具，或实现同名 wrapper。
export DOC_CLI="doc-cli"
