# loop-daily-retro 配置示例
#
# 复制成本地真实配置（如 ~/.config/loop-daily-retro.sh），填好后由脚本 source。
# 真实值绝不要提交进这个公开仓库。

# 复盘署名（出现在日记文档标题里）
export REPORT_OWNER="Your Name"

# 通知命令：接收一个字符串参数，推送到你的即时通知渠道。留空则只写日志。
export NOTIFY_CMD="notify-send-im"

# 文档 CLI：创建/更新云文档的命令行工具。参考实现依赖一个私有 CLI，你需自备。
export DOC_CLI="doc-cli"

# 可选：IM 素材抓取命令。若设置，digest 会调它抓「当天的自我笔记 / 私聊 / @我」等
# 即时通讯素材，追加到复盘素材的 PART 2。命令签名：<cmd> <YYYY-MM-DD>，输出纯文本到 stdout。
# 不设置则 PART 2 只提示「未接入 IM 素材」，复盘只基于 session。
export IM_DIGEST_CMD=""

# 累积改进计划文档 / 复盘索引文档的 token 会由脚本在首次运行后写入下面这两个状态文件，
# 无需手填（列在这里只为说明状态存放位置）。
# ~/.local/var/daily-retro-plan-token
# ~/.local/var/daily-retro-index-token
