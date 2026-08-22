# loop-skill-optimizer 配置示例
#
# 用法：复制成本地真实配置（放在仓库之外，比如 ~/.config/loop-skill-optimizer.sh
# 或你的 secrets.sh），填好后由 scripts/optimizer.sh 在启动时 source。
# 真实值绝不要提交进这个公开仓库。

# 你的 skill 仓库在 GitHub 上的 owner/repo（PR 会提到这里）
export SKILL_REPO_SLUG="your-github-name/your-skills-repo"

# 本地仓库工作副本的绝对路径
export SKILL_REPO_DIR="$HOME/github/your-github-name/your-skills-repo"

# 状态与日志目录（幂等戳、主题账本、denylist、每次运行产物都放这里）
export OPTIMIZER_STATE_DIR="$HOME/.local/var/skill-optimizer"

# 每日提 PR 的调度时间点（小时，24 小时制）。过了这个点且当天没成功跑过才会跑分析。
export OPTIMIZER_SCHED_HOUR=21

# 通知命令：接收一个字符串参数，把它推送到你的即时通知渠道（IM 私聊 / 邮件 / webhook）。
# 这里默认调用一个名为 notify-send-im 的外部命令，你需要换成自己的实现，
# 或写一个同名 wrapper。留空则不发通知（只写日志）。
export NOTIFY_CMD="notify-send-im"
