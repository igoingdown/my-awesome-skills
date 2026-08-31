---
name: session-archaeology
description: 跨 session 工作考古——从历史 Claude Code session 里找回某项工作的结论、分支、PR 状态，并支持恢复(resume)。使用时：用户说"我之前在哪个 session 做过 X""找一下之前的分析结论""那个 session 是哪个？我怎么找不着了""那个 session 提的 PR 合了吗、合入了吗""我要 resume 那个 session"时触发。核心动作：关键词定位 transcript → 抽取结论与交付物 → 用 git/gh 对账真实状态 → 给出 resume 指引。
---

# Session Archaeology（跨 session 工作考古）

用户把历史 session 当成可检索的工作档案：一件事做过就应该能找回来——结论在哪、开的哪个分支、PR 提了没合了没、能不能接着做。本 skill 是这类请求的标准手法。请求通常混合四问：**定位**（哪个 session）、**取结论**（当时分析出了什么）、**对账**（PR/分支现在什么状态）、**恢复**（要不要 resume）。四问按序做，做到用户要的那一步为止。

## Transcript 在哪里

- 每个 session 一个 JSONL：`~/.claude/projects/<目录slug>/<session-id>.jsonl`，`<目录slug>` 由 session 的工作目录路径把 `/` 换成 `-` 得到，文件名就是 session id。
- **worktree 里的 session 存在独立的 slug 目录下**（worktree 路径不同于主仓路径）。找一个仓库的历史工作时，主仓 slug 和它的 `*-claude-worktrees-*` slug 都要搜。
- 同一条工作线可能散在多个 transcript（用户中途新开过 session、或换了 worktree）。都列出来按时间线拼，别只认第一个命中。

## 步骤 1：定位候选 session

1. 从用户的描述里提 2~3 个**高区分度关键词**：业务名词、字段/表名、分支名、报错原文。别用"修复""问题""优化"这类通配词——会命中几百处。
2. 先猜项目缩小范围（用户提到的仓库 → 对应 slug 目录及其 worktree slug），猜不到再全 `~/.claude/projects/` 搜。
3. **transcript 是十几 MB 级大文件，禁止整读**。第一轮只列文件：`grep -l '关键词' <dir>/*.jsonl`；命中多个按 mtime 排序，新的优先。
4. 关键词是固定字符串就直接 grep；若必须用带大范围有界量词的正则，遵守全局 grep 安全规则（`command grep` + 两步走）。

## 步骤 2：确认是那件事

对每个候选：`grep -n` 定位命中行号，再用 python 按行号切片抽出附近的**用户消息**核对（JSONL 每行一个事件，用户消息在 `type=user` 行的 `message.content` 里）。用户对当时措辞的记忆常不准——概念对得上就算命中，对不上就换同义词再搜。搜不到用户消息时改搜**助手消息**：交付物词汇（PR 编号、分支名、文档链接）多半出现在助手侧。

## 步骤 3：抽取结论与交付物

- 结论优先从 session **尾部**找：最后几轮的总结、`This session is being continued` 的 compaction 摘要段（它本身就是前文的浓缩，很好用）。
- 交付物用定向 grep：`github.com/.*/pull/`、分支名模式、云文档链接。把找到的 PR 号/分支名/文档链接原样列给用户，并附 transcript 路径便于回看。

## 步骤 4：对账——transcript 只是线索，状态以外部系统为准

transcript 里写"已提 PR"不等于现在已合入；写"待办"的可能早已被别的 session 做完。凡涉及状态的问题一律回外部系统对账：

- PR 状态：`gh pr list --head <分支> --state all` / `gh pr view <编号>`；
- 分支是否已进主干：`git log --oneline main | grep`、`git branch -a --contains`；
- worktree 还在不在：`git worktree list`。

汇报时分开说"当时 session 里的说法"和"现在对账到的事实"，不一致以对账为准。

## 步骤 5：resume 指引（用户要接着做时）

- 给出 session id 与原工作目录，提示在**原目录**下 `claude --resume <session-id>`（worktree session 要回到那个 worktree；worktree 已删则说明状况，建议带着找回的结论开新 session）。
- 用户只要结论不要恢复时，直接汇报结论+对账结果即可，不必引导 resume。

## 坑

- **别在全部项目目录上跑重型搜索**：几十个项目 × 每个几十个大 JSONL，全量正则会拖垮共享机器。先缩目录、只 `grep -l`、串行来。
- **命中行≠用户原话**：compaction 摘要、工具输出里也会出现关键词。核对时认准 `type=user` 的行。
- **时间线陷阱**：mtime 是最后活动时间，不是这件事发生的时间；长寿 session 里要用消息里的 `timestamp` 字段定位到具体日期。
- **一无所获时**如实报：搜过哪些目录、用过哪些关键词、建议用户补一个更独特的词（当时的表名/报错/PR 号片段），别硬猜一个 session 交差。
