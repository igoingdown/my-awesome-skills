---
name: codex-adversarial-review
description: 把一份技术文档（spec / 设计方案）、一段代码 / 一个 PR、或「文档 + 代码」一起发给外部 CodeX CLI 做深度对抗式（adversarial）评审，作为开工实现 / 合入前的最后一道独立质量门。CodeX 是与本 Agent 完全独立的第二意见来源（独立模型 + 独立读码 + Web Search 取证），强制做文档↔代码交叉验证，并要求每条 SOP/最佳实践建议都给出权威出处 URL。当用户说"发给 CodeX review""做一轮对抗式评审""找 CodeX 挑刺""第二意见""spec 评审""代码评审""开工前/合入前最后把关"等场景时调用。强制使用外部 CodeX CLI，禁止用本 Agent 自己派生的 Sub-Agent 冒充。
---

# CodeX Adversarial Review —— 对抗式评审（文档 / 代码 / 交叉）

## 这个 skill 解决什么问题

自己写的 spec、自己改的代码，自己再怎么 review 都带着确认偏误——你信任自己引用的 file:line，信任自己的根因判断。**CodeX 是一个完全独立的第二意见**：独立的模型、独立地把代码重新读一遍、不预设你的结论对。它的职责是**证伪**，不是附和。

适合在"方案已定、即将开工实现"或"代码写完、即将合入"的节点跑，作为最后一道门。

**本 skill 的三个能力**（相比普通评审的增强）：
1. **三种评审对象**：纯文档 / 纯代码 / 文档+代码（推荐）。
2. **文档↔代码交叉验证**：对文档里每一条关于代码的断言，回到真实代码核对是否一致。
3. **Web Search 取证的 SOP 建议**：所有"最佳实践/反模式/业界标准"类建议**必须带权威出处 URL**，且与在审代码/文档交叉验证后给出，杜绝凭记忆空谈。

> ⚠️ **铁律：必须用外部 CodeX CLI（`codex exec`），绝不能用本 Agent 自己派生的 Sub-Agent 顶替。** 自己的 Sub-Agent 与主 Agent 同模型、共享上下文偏见，起不到"独立第二意见"的作用，等于自己 review 自己。

---

## 前置条件

- [x] 评审对象已就绪：文档已落盘 / 代码已写完（或 PR 分支已存在）
- [x] `codex` CLI 可用：`which codex`（本机在 `~/.superset/bin/codex`，版本 ≥ 0.142.0）
- [x] CodeX 已配置好可用模型（`~/.codex/config.toml`，本机为 `gpt-5.5` 走自建网关）
- [x] CodeX 的 Web Search 可用（启动时加 `--search`，见步骤 2）

---

## 输入与输出

**输入**：
- 评审对象（三选一）：文档路径 / 代码范围（文件、目录、或 `分支 vs main` 的 diff）/ 两者
- 评审关注点（可选；用户没给就由本 skill 按"对抗式通用清单"自动生成）

**输出**：
- `<工作目录>/codex-review-prompt.md` —— 发给 CodeX 的评审指令（留档，可复跑）
- `<工作目录>/codex-review.md` —— CodeX 产出的评审报告（含 Findings + **Sources cited** SOP 出处清单）
- 本 Agent 对 CodeX 报告的**二次评估**（逐条复核属实/夸大/误读，并**核验它给的 SOP 出处是否真实可达**，给上线/合入建议）

---

## 核心工作流

```
1. 定评审对象（文档 / 代码 / 交叉），写评审指令 (codex-review-prompt.md)
        │
        ▼
2. 异步启动 CodeX (codex exec --search, xhigh 推理, run_in_background)
        │
        ▼
3. 定期轮询产出文件 (codex-review.md 是否生成 / 进程是否退出)
        │
        ▼
4. CodeX 完成后，本 Agent 逐条复核 findings（回代码验证）+ 核验 SOP 出处可达
        │
        ▼
5. 给出二次评估：哪些 must-fix / 哪些夸大 / 哪些误读 / 哪些 SOP 出处站不住 + 上线建议
```

---

### 步骤 1：写评审指令 `codex-review-prompt.md`

把评审指令写成独立文件（而非只在命令行传字符串），好处：留档、可复跑、CodeX 能完整读到。

**先定评审对象**（决定 prompt 保留哪些段落）：
- **A. 只评审文档**（spec / 设计方案）
- **B. 只评审代码**（一段实现 / 一个 PR / 一组文件 / 一个 diff）
- **C. 文档 + 代码（推荐）**——重点是交叉验证

指令必须包含的要素：

1. **角色定位**：明确要求"DEEP, ADVERSARIAL（深度对抗式）"评审，**be adversarial, not agreeable**（找茬，别附和）。
2. **上下文**：项目名 + 一句话技术栈 + 评审对象 + 它想解决什么。
3. **待评审材料**：文档路径 / 代码范围 / 关键文件清单（引导 CodeX 去核）。
4. **评审方法硬要求**：
   - **回到真实代码核对**：不信任何 file:line 引用、注释、commit message、散文描述——自己打开文件看，磁盘上的代码才是真相。
   - **文档↔代码交叉验证**（对象含两者时）：文档每条关于代码的断言，逐条回代码核是否属实；方案是否匹配代码实际能力（签名、数据形状、可空性、调用顺序、事务边界）；有没有代码现实被文档漏掉、或文档要求无对应代码。
   - **挑战实质**：根因是否成立、方案是否有更优解、边界 case、跨层一致性、成本/延迟是否被低估、fail-safe 是否合理、测试是否覆盖风险点。
   - **SOP 取证（关键）**：用 **Web Search 工具**给最佳实践类建议取证；**每条 SOP/反模式/业界标准必须带权威出处（名称 + 可解析 URL，必要时含章节/版本）**，并与在审代码/文档**交叉验证后**给出；找不到权威源就如实说明并降级为"个人观点"，不得把无源建议包装成标准。
5. **输出格式**：写到指定路径 `codex-review.md`，结构固定：
   - **Verdict**（yes / yes-with-changes / no）
   - **Findings**：每条标严重度（BLOCKER / MAJOR / MINOR / NIT）+ claim/代码位置 + 代码验证（引真实 file:line；交叉评审时给"文档断言 vs 代码现实"）+ 为什么是问题 + 具体修法 + **若涉及 SOP 则附出处名 + URL**
   - **Sources cited**：所有用到的 SOP/标准/参考 URL 汇总清单（便于逐条核验）
   - **What the target got right**（避免回归已验证的正确决策）
   - **Open questions**（开工/合入前必须回答的问题）
6. **约束**：**只写评审文件，不许改任何源代码。**

> 模板见本目录 `review-prompt-template.md`，已内置 A/B/C 三种对象的取舍说明。

### 步骤 2：异步启动 CodeX

用 `codex exec` 非交互模式，**异步后台运行**（评审耗时长，xhigh 推理 + Web Search 可达数分钟到十几分钟）：

```bash
codex exec \
  -c model_reasoning_effort="xhigh" \
  --search \
  --cd "<repo 根目录>" \
  --skip-git-repo-check \
  - < <工作目录>/codex-review-prompt.md
```

要点：
- **`-c model_reasoning_effort="xhigh"`** —— 即 **Thinking level = Max**。可选值 `minimal|low|medium|high|xhigh`，对抗式深评固定用 `xhigh`。
- **`--search`** —— 启用 CodeX 原生 `web_search` 工具，让它能联网取 SOP 出处（这是"SOP 必带来源"的前提，**不加这条则取证要求落空**）。
- **`-` + stdin 重定向** —— 把 prompt 文件喂给 CodeX（也可作为 `[PROMPT]` 参数，但 stdin 更稳，长文档不撞命令行长度限制）。
- **`--cd <repo 根>`** —— 让 CodeX 在仓库根作业，才能按 file:line 打开文件核对。
- **模型** —— 默认走 `~/.codex/config.toml` 的 `gpt-5.5`；要覆盖加 `-m <model>`。
- **沙箱** —— 默认 read-only 即可（评审只读不改）；指令里也已明令禁止改源码，双保险。
- 用工具的 `run_in_background` 起这条命令；记下返回的进程/任务标识，供轮询。

### 步骤 3：定期轮询

- **不要 `sleep` 空等**；用 `run_in_background` 起的进程会在结束时自动通知，到时再看产出。
- 若需主动确认进度：检查 `codex-review.md` 是否已生成 / 是否还在增长，或看后台进程是否退出（exit 0 = 正常完成）。
- 轮询命令（中性、可重复）：`ls -la <工作目录>/codex-review.md 2>/dev/null && wc -l <工作目录>/codex-review.md`。

### 步骤 4 + 5：本 Agent 二次评估 CodeX 的报告（**最关键，别省**）

CodeX 完成后**不要直接把它的结论丢给用户**。CodeX 也会夸大、误读、定级偏重，甚至**给出失效或牵强的 SOP 出处**。本 Agent 必须**逐条回到代码里复核**，并**核验它引用的每个 SOP URL 是否真实、权威、确实支撑该结论**：

对每条 finding 判定：
- **✅ 属实** —— 复核代码确认成立 → 该改。
- **⚠️ 属实但定级过重** —— 问题真实但危害/概率被高估（如把"窄窗口、低危害、可自愈"的问题定成 BLOCKER）→ 降级，说明理由。
- **❌ 误读/夸大** —— CodeX 误解了原意，或代码并非它说的那样 → 反驳，引代码证据。
- **🔗 SOP 出处核验** —— URL 是否可达？是否权威源（官方文档/OWASP/RFC 等）而非随手博客？该源是否真的支持这条建议？出处站不住的，把建议降级为"观点"。
- 区分 **must-fix** 与 **过度设计建议**（CodeX 常爱加新字段/新抽象，对低频功能往往不值当）。

最后给用户一个**净结论**：综合 CodeX + 本 Agent 复核后，能不能开工/合入、之前需要改哪几处。

---

## 反模式（别这么干）

- ❌ 用本 Agent 自己的 Sub-Agent（Task/Agent 工具）冒充 CodeX —— 违背"独立第二意见"的全部意义。
- ❌ 不加 `--search` —— "SOP 必带来源"会落空，CodeX 只能凭记忆空谈。
- ❌ 推理强度用默认/low —— 对抗式深评必须 `xhigh`。
- ❌ 同步阻塞等 CodeX / 用 `sleep` 轮询 —— 用后台 + 完成通知。
- ❌ 把 CodeX 的报告原样转述给用户 —— 必须先逐条复核 + 核验 SOP 出处，CodeX 不是权威。
- ❌ 接受无出处的"最佳实践"建议 —— 没有权威 URL 的 SOP 一律降级为观点。
- ❌ 让 CodeX 顺手改代码 —— 评审与实现严格分离，指令里明令只写评审文件。
- ❌ 全盘照单全收 CodeX 建议 —— 尤其它爱加的新字段/新抽象，对低频功能多半是过度设计。

---

## 一个完整案例（本 skill 的来源）

`specs/2026-06-24-admin-review-globe-key-no-gating/` 是一次真实跑通（当时为文档+代码交叉评审）：
- `codex-review-prompt.md` —— 对抗式评审指令（要求逐条核码、固定输出结构）。
- `codex-review.md` —— CodeX 产出（Verdict: No；1 BLOCKER + 3 MAJOR + 2 MINOR + 1 NIT）。
- 本 Agent 二次评估：复核后认为 BLOCKER 属实但**定级过重**（窄窗口、低危害、可自愈），其余 6 条 5 条属实、1 条误读 spec；净结论"可开工，开工前做 4 处小修"，并据此修订了 spec。
