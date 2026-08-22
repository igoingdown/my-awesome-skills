---
name: loop-skill-optimizer
description: 一个「让 skill 库自己进化」的每日自动化 loop 的设计与参考实现。它每天分析自己的 Claude Code session、把反复强调的工作方式提炼成 skill 优化、自动提 PR，合入后再自动同步回运行时。适合想搭建「AI 自我改进闭环」或「用定时 headless Claude 做无人值守分析并产出代码 PR」的人参考。触发词：skill 自进化、自动提 PR、headless 定时分析、session 复盘沉淀、AI 自我改进闭环、cron + claude -p。
metadata:
  kind: loop
  schedule: "*/30 * * * *  (+ @reboot)"
  surface: cron + headless-claude + git-PR + IM-notify
  desensitized: true
---

# loop-skill-optimizer

> 这是一个 **loop skill**（自动化循环），不是普通的能力型 skill。它沉淀的是「一个每日自我进化 loop 该怎么设计」的完整思路 + 一份去敏的可执行参考实现。真实运行需要按 `config.example.sh` 填好本地配置。

一句话：**每天读自己昨天和 Claude 的所有对话，把我反复强调、反复纠偏的工作方式，自动沉淀成对 skill 库的改进，提成 PR；我合入后它再自动把新 skill 同步回运行时目录。** 一个自我改进的闭环。

## 为什么要有这个 loop

人跟 AI 协作时，最有价值的信号是**重复的纠偏**——同一类要求被反复强调，说明 AI 没记住、而这条对你很重要。这些信号散落在几百个 session 里，靠人回头翻不现实。这个 loop 把它自动化：高频信号 → 结构化账本 → skill 改进 → 下次加载生效。

## 整体架构：两个 Phase 挂在同一个 30 分钟 tick 上

crontab 每 30 分钟调一次 `optimizer.sh --cron`，脚本内部分两段：

- **Phase A（合入同步）**：远端 main 有新提交就 fast-forward 本地、跑 `sync.sh` 把 `skills/` 拷到运行时目录、发通知。这等价于「我在手机上点了合入 PR，30 分钟内运行时 skill 自动更新」。
- **Phase B（每日分析）**：过了当日调度点（默认 21:00）且当天没成功跑过，才跑一次。提取窗口内 session 用户消息 → headless `claude -p` 两阶段分析 → 敏感词闸门 → 提 PR → 通知。

两段共用一把 `flock` 文件锁，`--cron` 抢不到锁直接退出，避免 tick 叠跑。

## Phase B 的两阶段 prompt（这是设计精华）

早期版本只有「分析→提 PR」一步，抓不住**跨天重复**的信号——24h 窗口只覆盖 1~2% 的历史，NOPR 就把信号丢了、不累积。改成两阶段后才解决：

1. **记账阶段（每次必做，与提不提 PR 无关）**：把观察合并进一个**跨天主题账本**（`themes.md`，在仓库之外）。命中已有主题就计数 +1、追加日期与原话线索；新主题就新建（状态=观察中）。这一步保证信号不丢、能累积。
2. **晋升阶段**：只有账本里**出现 ≥3 次且跨 ≥2 个不同日期**的主题才晋升为 PR 候选。当日一次性的强纠偏（明确说「写进记忆/这是纪律/以后都要」）可**破格**晋升，但要在 PR 描述里注明破格理由。够格的才改 skill、提 PR，并把主题标「已提PR」。

晋升后**优先并入最相关的已有 skill**（先读原文件、遵循其风格、改动小而准），确实无家可归才允许新建 skill（一次最多一个，且要在 PR 里说明为何不并入）。

## 关键设计决策与踩过的坑

- **频率导向，不是事件导向**：值不值得沉淀由「跨天出现次数」决定，不是「这条看起来重不重要」。这是避免过度反应的核心。
- **周日全量复扫**：日常窗口是 24h，周日扩到 14 天，专门补日常窗口漏掉的跨天慢信号。判据 `date -d "$due" +%u == 7`。
- **digest 别截断**：早期 `MAX_MSG`/`MAX_LEN` 太小，长会话的用户消息被大量丢弃（曾有 18 个 session 丢了上千条），高频信号直接看不见。调大到能覆盖长会话。
- **幂等戳 + 补跑**：`last-run-date` 记最近成功分析的目标日期；服务器重启/宕机错过调度点，靠 `@reboot` 和后续 tick 自动补跑当天。
- **失败重试有上限**：连续失败 ≤3 次继续重试，到顶就通知人工并写完成戳止损，不无限刷。
- **Phase A 的干净门禁会被脏工作区卡住**：只在「本地在干净 main 上」时才同步。如果仓库根目录躺了未跟踪文件（比如 headless 会话的转储、临时产物），`git status` 非空 → 每次 tick 都跳过同步、反复发 dirty 告警，能卡好几个小时。**排查口径**：`git -C <repo> status -sb`，清掉/移走 stray 文件即可，别去动门禁逻辑本身。

## 脱敏红线（这个 loop 自己产出公开 PR，红线尤其硬）

因为这个 loop 会**自动往公开仓库提 PR**，它有双层防线：

1. **prompt 里写死红线**：公司名/内部服务名/同事名/内部域名·IP·端口/token·ID/生产日志原文一律禁止出现在 commit、代码、PR 文案里；具体案例必须抽象成通用场景。
2. **外层脚本敏感词硬闸门**：push 前用 `denylist.txt`（ERE 一行一个，本地维护、不进仓库）扫**新增行 + commit 消息 + PR 文案**，命中即拦截、转人工。带**存量豁免**：命中词若在该文件/仓库的 `origin/main` 版本已存在，说明不是本次新引入，放行；从没出现过的（密钥、IP、ID）一律拦。

**主题账本 `themes.md` 含我的逐字原话，永远不进仓库**；从账本流到 skill 文件的内容必须先脱敏抽象，绝不逐字复制。

## headless claude 的权限收敛

Phase B 调 `claude -p` 时：
- `--allowedTools` 只给 `Bash,Read,Write,Edit,Grep,Glob`
- `--disallowedTools` 明确禁掉 `git push` / `gh pr create` / `gh pr merge` / `gh repo`——**push 与建 PR 只能由外层脚本在敏感词扫描通过后做**，模型自己碰不到。
- `--max-turns` 设上限、`timeout` 包整个调用，防跑飞。

## 安装与自检

```bash
./install.sh init-config     # 生成本地配置模板到 ~/.config/loop-skill-optimizer.sh
$EDITOR ~/.config/loop-skill-optimizer.sh   # 填真实值（不要提交）
./install.sh doctor          # 自检依赖（git/gh/claude/python3）与配置
./install.sh install-cron    # 装 crontab（*/30 + @reboot）
```

手动验证：`optimizer.sh --dry-run` 会完整跑一遍分析并过敏感词扫描，但**不 push、不建 PR、不写完成戳**，用来验证链路。

## 需要你自备/替换的东西

- **通知渠道**：脚本调 `$NOTIFY_CMD "<消息>"` 推送。参考实现里这是一个私有 IM 的 CLI，你需要换成自己的（邮件 / webhook / 任意 IM）。留空则只写日志。
- **`sync.sh`**：仓库根目录的同步脚本，把 `skills/` 拷到你的运行时 skill 目录。
- **`denylist.txt`**：你自己的敏感词清单，放在状态目录、不进仓库。
- **GitHub CLI `gh`** 已登录、对目标仓库有 push 权限。

## 与其他 skill 的边界

- 本 skill 讲「一个自我进化 loop 怎么设计与落地」。若你要沉淀的是别的定时任务（周报、日报复盘），见 `loop-weekly-report`、`loop-daily-retro`——它们共享「cron + headless claude + 去敏配置外置」的同一套范式。
- 具体「一条工程任务该怎么做」的通用纪律在 `working-discipline`。
