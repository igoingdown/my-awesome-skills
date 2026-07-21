---
name: codex-adversarial-review
description: 用外部 CodeX CLI 对文档（spec/设计方案）、代码/PR、或两者一起做对抗式独立评审。当用户说"发给 CodeX review""对抗式评审""找 CodeX 挑刺""第二意见""spec/代码评审""开工前/合入前把关"时调用。
---

# CodeX Adversarial Review —— 对抗式评审（文档 / 代码 / 交叉）

把评审对象交给**外部 CodeX CLI**做独立第二意见。CodeX 用独立模型、独立读码、不预设你的结论对，职责是**证伪而非附和**。适合"方案已定将开工"或"代码写完将合入"的最后一道门。

**三个增强能力**：
1. **三种评审对象**：纯文档 / 纯代码 / 文档+代码（推荐）。
2. **文档↔代码交叉验证**：文档里每条关于代码的断言，回真实代码核对。
3. **Web Search 取证的 SOP**：最佳实践/反模式类建议**必须带权威出处 URL**，与在审代码交叉验证后给出。

> ⚠️ **铁律：必须用外部 CodeX CLI（`codex exec`），绝不能用本 Agent 自己派生的 Sub-Agent 顶替。** 同模型、共享偏见 = 自己 review 自己，失去独立第二意见的意义。

## 前置条件

- 评审对象已就绪（文档落盘 / 代码写完 / PR 分支存在）
- `codex` CLI 可用（`which codex`，版本 ≥ 0.142.0）+ 已配模型（`~/.codex/config.toml`）
- 启动加 `--search` 以启用 Web Search（SOP 取证的前提）

## 工作流

```
1. 定评审对象，写指令 codex-review-prompt.md
2. 异步启动 CodeX (codex --search exec, xhigh, bypass-approvals-and-sandbox, run_in_background)
3. 轮询产出文件 codex-review.md
4. 本 Agent 逐条复核 findings + 核验 SOP 出处可达
5. 给净结论：must-fix / 夸大 / 误读 / SOP 站不住 + 上线建议
```

**步骤 1 — 写指令**：把评审指令写成独立文件（留档、可复跑）。必含要素、A/B/C 三种对象取舍、强制输出结构，见 `references/review-instructions.md`；填空式模板见 `review-prompt-template.md`。

**步骤 2 — 启动**：用 `codex --search exec` 异步后台运行，命令与逐项要点见 `references/codex-invocation.md`。关键：顶层 `--search`（取 SOP 出处，必须放在 `exec` 之前）+ `model_reasoning_effort=xhigh`（Thinking=Max）。

**步骤 3 — 轮询**：不要 `sleep` 空等，靠后台完成通知；进度查看见 `references/codex-invocation.md`。

**步骤 4+5 — 二次评估（最关键，别省）**：CodeX 会夸大/误读/定级偏重/给失效出处。逐条回代码复核 + 核验每个 SOP URL，再给用户净结论。判定四档（✅属实 / ⚠️定级过重 / ❌误读 / 🔗出处核验）、反模式清单、完整案例，见 `references/evaluation-and-antipatterns.md`。

## 循环评审（review-until-pass）纪律

用户常要求"修完自动再发 CodeX 审，直到通过为止"。多轮循环最容易失控，按以下纪律执行：

1. **逐轮编号留档**：每轮产出 `codex-review-r<N>.md`（指令同理 `codex-review-prompt-r<N>.md`），从 r1 起算；每轮净结论必须写明本轮 verdict + 上一轮 findings 的逐条处置（已修 / 驳回 / 降级），不能只贴新报告。
2. **收敛条件要明确**：verdict 为 yes / yes-with-changes 即收敛停止。连续两轮出现同一批 findings（修了又被提）说明修法有分歧，**停下来找用户对齐**，不要无限打转烧钱。
3. **每轮启动前清点进程——只清账本、kill 必须用户确认**：
   - **启动即记账**：setsid 启动 codex 后立刻把 PID/PGID 写入当轮产物目录（如 `codex-r<N>.pid`）。账本是判定"残留"的唯一依据——发现的进程 ≠ 你启动的进程。
   - **清点只看自己**：用 `pgrep -u "$(id -un)" -f '^codex .*exec'`。禁止 `ps aux` 全局清单：共享机上会列出其他用户的进程，宽模式 `codex.*exec` 还会把 grep 自身、包装 shell 误算成"残留"，而它们可能是其他会话正在跑的正经评审。
   - **kill 是高危动作，必须先向用户列出清单（PID、启动时间、完整命令行、判定依据）并得到明确确认后才执行**——即使进程在自己账本里也一样；杀错一个并行会话的 codex，整轮评审白跑。无人值守场景（cron / headless / 自动循环）**一律不 kill**，只把清单写进产物留给用户处置。
   - 唯一免确认的例外：本轮内自己刚启动、且已确认失败要重试的那个 PID（账本可证）。`kill` 返回 `Operation not permitted` 说明进程不属于你，**严禁转 sudo 重试**。
4. **评审对象过长先减负**：待审文档很长（如超 ~2000 行，或多文件合计远超一次上下文）时，**不要把全文内嵌进 prompt**——prompt 里只放文件路径清单 + 关注点，让 CodeX 靠 `--cd` 自己按需读文件；仍然过长就按章节拆成多轮分片评审。全文内嵌长文档是"反复 API retry / 上下文溢出"的头号诱因，且每轮循环都会重复付出这个成本。

## 输入与输出

**输入**：评审对象（文档路径 / 代码范围 / 两者）+ 关注点（可选）。

**输出**：
- `<工作目录>/codex-review-prompt.md` —— 评审指令（留档）
- `<工作目录>/codex-review.md` —— CodeX 报告（含 Findings + Sources cited 出处清单）
- 本 Agent 对报告的**二次评估** + 上线/合入建议

## 为什么不用原生 `codex review`

CodeX 自带 `codex review` 子命令（`--base` / `--commit` / `--uncommitted` 自动选 diff 范围）。看起来能简化本 skill，但 0.133 实测有两个致命限制，**不适合替代本 skill 的对抗式取证评审**：

1. **`codex review` 不支持联网搜索。** 顶层 `--search` 对 `review` 无效，`-c tools.web_search=true` 也救不回——实测同一 prompt 在 `review` 下返回 `WEB_SEARCH_UNAVAILABLE`，而 `codex --search exec` 能真实搜到权威 URL。本 skill 的铁律「SOP 必带权威出处」依赖搜索，换 `review` 直接失效。
2. **范围 flag 与自定义 PROMPT 互斥。** `--base` / `--commit` / `--uncommitted` **不能和 `[PROMPT]` 同时使用**（报 `cannot be used with '[PROMPT]'`）。即「自动选范围」和「注入对抗式指令」二选一，等于它唯一的优势也用不上。

因此本 skill 固定走 `codex --search exec`（注入完整对抗式 prompt + 联网取证），不使用 `codex review`。`codex review` 仅适合「纯代码 diff、不需 SOP 取证」的轻量场景，不在本 skill 范围内。
