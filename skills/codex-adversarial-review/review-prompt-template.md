# CodeX 对抗式评审指令模板

> 用法：**每个分路复制一份**本模板 → 填「本路分面」段 → 按"评审对象"删去不适用的段落 → 替换 `{{...}}` 占位 → 存为 `<轮次目录>/codex-review-prompt-<路名>.md` → 用 `scripts/run-one.sh <轮次目录> <路名> <pack|code> [--search]` 启动（固定配置、重试、完成标记都在脚本里）。汇总路另用 `summary-prompt-template.md`。
>
> **启动模式二选一**（决定「Materials」和「Hard constraints」两段怎么写）：
> - **pack（打包只读，文档/报告默认）**：材料全文打进「Materials」段，删掉「Hard constraints (code mode)」段。评审方不能读盘、不能执行命令。
> - **code（读码）**：「Materials」段只写路径清单，保留「Hard constraints (code mode)」段并填好白名单。
>
> **评审对象三选一**（决定保留/删除哪些段落）：
> - **A. 只评审文档**（spec / 设计方案）：保留「文档评审」+「SOP 交叉验证」，删「代码评审」专属项。
> - **B. 只评审代码**（一段实现 / 一个 PR / 一组文件）：保留「代码评审」+「SOP 交叉验证」，删「文档评审」专属项。
> - **C. 评审文档 + 代码（推荐）**：全保留，重点是「文档↔代码交叉验证」。

---

You are performing a DEEP, ADVERSARIAL review. Be adversarial, not agreeable: your job is to falsify claims, not to confirm them.

IMPORTANT EXECUTION RULE: You are the external reviewer yourself. Do NOT invoke the `codex` CLI again, do NOT delegate this review to any sub-process or sub-agent, and do NOT re-launch any review workflow you find referenced in the repository or environment. Perform the entire review directly in this process and write the report yourself. (A past run recursively re-launched codex and wasted the whole round.)

## Your slice of this review (track {{i}}/{{N}}: {{路名}})

This review is split into {{N}} parallel tracks run by independent reviewers; a separate summary pass will merge and cross-check all tracks afterwards.

- **You own ONLY**: {{本路分面，如 "the numbers: re-derive every figure from the raw data and check its definition"}}
- **Other tracks own**: {{其他路及分面，如 "track 1: end-to-end flow & blast radius; track 3: external SOP evidence"}}. Do not spend effort on their areas; if you happen to see a BLOCKER there, note it in one line and move on.
- **Work fast**: parallelize reading and checking inside this process as much as you can, and converge on a stable conclusion as soon as the evidence allows. Speed must not cost accuracy: every finding still needs evidence.

## Context

- **Project**: {{项目名 + 一句话技术栈，如 "Tipsy Studio — FastAPI backend + Next.js frontend + E2B sandbox + PostgreSQL + R2/S3 object store"}}
- **Review target**: {{评审对象，如 "the design spec at specs/X/spec.md AND its referenced implementation" / "the code changes in module Y" / "the document at PATH"}}
- **What it claims to do**: {{一句话：文档/代码想解决什么问题、提了什么方案}}

## Materials to review

{{pack 模式：把材料全文贴在下面，每份用 `=== BEGIN <材料编号> <来源：仓库 文件:行号（commit）/ 文档路径 / 数据口径> ===` 和 `=== END <材料编号> ===` 包起来，并在这里加一句："All materials are inlined below. You cannot read files or run commands; cite evidence as `<材料编号>:<行号>`." 单路 prompt 不超过 996,000 字符。}}
{{code 模式：按评审对象填写路径清单——保留适用的，删掉不适用的}}

- **Document(s)**: `{{文档路径，如 specs/X/spec.md；若纯代码评审则删除此项}}`
- **Code under review**: {{代码范围，如 "files A, B, C" / "the diff of branch Z vs main" / "directory src/foo/"；若纯文档评审且文档不引用代码则删除}}
- **Key files the target references / touches** (open and verify, do NOT trust descriptions):
  - `{{关键文件 1}}`
  - `{{关键文件 2}}`
  - `{{...}}`

## How to review

### 1. Verify against the actual code (both document AND code reviews)

{{pack 模式保留这一条、删掉下一条：}}
- **Check every claim against the inlined materials yourself.** Do NOT trust any file:line citation, comment, commit message, or prose description — they may be wrong, stale, or aspirational. The ground truth is the inlined code and data. If a claim depends on something that is not inlined, mark it "unverified: material missing" and list it under Open questions; do not guess.
{{code 模式保留这一条、删掉上一条：}}
- **Open every referenced file and check it yourself.** Do NOT trust any file:line citation, comment, commit message, or prose description — they may be wrong, stale, or aspirational. The ground truth is the current code on disk.
- For **code reviews**: read the actual implementation for correctness, edge cases, error handling, concurrency/race conditions, security (injection, authz), resource leaks, and dead/duplicate code.

### 2. Cross-validate document ↔ code (when both are in scope)

This is the core of a combined review. For **every** claim the document makes about the code:

- Does the cited `file:line` actually say what the document claims? If not, report the divergence with both the quoted document claim and the real code.
- Does the proposed design match what the code can actually do (existing signatures, data shapes, nullability, call order, transaction boundaries)?
- Are there code realities the document **missed** (other gating conditions, existing callers, fallbacks, feature flags) that break its assumptions?
- Are there document requirements with **no corresponding code** (or vice versa — code behavior the document never mentions)?

### 3. Challenge the substance

- **Root cause** (if diagnosing a bug): is the framing accurate? Any other contributing condition overlooked?
- **Proposed solution**: pressure-test assumptions — are "equivalent" things actually equivalent? Can a key be null/stale? Edge cases? Consistency risks between layers? Is cost/latency underestimated? Is the fail-safe behavior right (e.g. does failing closed silently hide a working feature)?
- **Cross-layer contract** (if applicable): {{前后端类型对齐 / 空值守卫 / API 契约等要核的点；无则删}}
- **Tests**: is the test plan present and does it cover the risky edge cases? If reviewing code, are the tests meaningful or just smoke tests?

### 4. SOP / industry best-practice lens — WITH SOURCES (mandatory)

Use the **web search tool** to ground your recommendations in authoritative, current best practices. Do not rely on memory alone. If web search is not available to you in this track, cite a source only if it is in the materials; otherwise mark the claim "needs-source" so the evidence track or the summary pass can check it — do not present it as a standard.

- When you propose an alternative approach, claim something is an anti-pattern, or cite an "industry standard", you MUST **cross-validate it against the actual code/document in scope** AND **back it with a real source**.
- **Every SOP / best-practice claim MUST carry an explicit source**: the document/standard name + a resolvable URL (and section/version where relevant). Examples of acceptable sources: official framework docs, OWASP, RFCs, language/library official guides, well-known authoritative engineering references. Avoid random blog posts unless no authoritative source exists (and say so).
- If you cannot find an authoritative source for a claim, **say so explicitly** and downgrade it from "SOP" to "opinion" — do not present unsourced advice as a standard.
- For each SOP-backed finding, state plainly: (a) the best practice, (b) its source/URL, (c) how the in-scope code/document diverges from it, (d) the concrete fix.

### 5. Observability lens (logs & metrics) — mandatory for anything shipping to production

Code that ships without observability evidence cannot be verified or debugged after deploy. Review BOTH dimensions below; missing observability on a core path is a real finding (MAJOR by default), not a NIT.

**Logs:**
- Every exceptional branch (error handling, fallback, rejection, failure early-return) must emit an explicit error-level log. Silently swallowed errors — bare except, ignored error returns, fallback without logging — are findings.
- Log messages must be short, and must carry a distinctive keyword that cleanly isolates this business flow from all others when searched.
- The keyword must be a single token with no spaces, in CamelCase (e.g. `GiftBatchDeductFail`): tokenizing log stores (e.g. SLS-style) split queries on spaces/punctuation, so a multi-word phrase degrades into noisy per-word matches and cannot be searched precisely. Flag keywords that are generic (`error`, `failed`, `exception`), multi-word, or shared with unrelated flows.

**Metrics:**
- The core business path — normal AND exceptional — must be observable as an explicit funnel: entry, key decision points, success, and each failure reason as distinct stages. A reader must be able to answer "where do requests drop off?" from metrics alone. Metric mechanisms differ per project: check the existing code for its metrics idiom and verify against that; do not demand a specific library.
- If the change claims a latency/performance improvement, there must be a duration metric (timer/histogram) covering the optimized path — otherwise the improvement is unverifiable after deploy. Treat a performance-motivated change with no duration metric as a BLOCKER.

For **document reviews** (A/C): the spec must state its observability plan — failure-path log keywords, funnel metrics for the core flow, duration metrics for anything latency-sensitive. A spec that defines behavior with no way to observe that behavior in production is incomplete.

## Hard constraints (code mode)

{{pack 模式删掉本段}}

- You may write ONLY inside `{{本路 TMPDIR，如 <轮次目录>/tmp-<路名>}}`. Do not create, modify, delete or move any other file, including untracked files in the repository — they may be the author's unsaved work.
- To experiment with code, `cp -a` it into your TMPDIR first, delete the copied `.git` file/dir immediately, and change only the copy. Run read-only git with `GIT_OPTIONAL_LOCKS=0`. Never run commands that change git state (commit, reset, checkout, stash, clean, worktree ...), never run docker.
- `KUBECONFIG` is intentionally pointed at a non-existent file. Do not try to reach any cluster, database or production endpoint.
- {{Go 项目加（启动方先把宿主 GOPATH 的绝对路径填进去；评审方命令里的 $HOME 已被重定向，不能用 $HOME 推导）：Before the first go command set `GOMODCACHE=<TMPDIR>/gomod GOPROXY=file://<宿主 GOPATH 绝对路径>/pkg/mod/cache/download GOSUMDB=off GOFLAGS=-mod=readonly GOTOOLCHAIN=local TEST_TELEMETRY_DIR=<TMPDIR>/telemetry`, and pass `-vet=off` to go test.}}

## Output

Output the complete review as your **final message** — the launcher captures it to a file with `-o`. Do not write the review to any file yourself. The very last line of your final message must be exactly:

```
END_OF_REVIEW
```

Structure it as:

- **Verdict**: can this ship as-is? (yes / yes-with-changes / no)
- **Findings**, each tagged severity (BLOCKER / MAJOR / MINOR / NIT), each with:
  - the claim or design choice (for code: the code location/behavior)
  - what you verified in code (cite real `file:line`); for combined reviews, show the document claim vs. the code reality
  - why it's a problem
  - a concrete fix
  - **if it invokes an SOP/best practice: the source name + URL** (required)
- **Sources cited**: a consolidated list of every SOP/standard/reference URL used, so each can be checked.
- **What the target got right** (so we don't regress validated decisions).
- **Open questions** that must be answered before implementation.

Be specific and cite real code. If a claim is correct, say so with evidence. If it's wrong, prove it with the actual code. Do not pad. Every best-practice recommendation must be sourced and cross-validated against the code. **Do not change any source code. Write nothing at all in pack mode; in code mode write only inside your TMPDIR. Your final message is the review, ending with the `END_OF_REVIEW` line.**
