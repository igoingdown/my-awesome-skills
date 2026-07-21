# CodeX 对抗式评审指令模板

> 用法：复制本模板 → 按"评审对象"删去不适用的段落 → 替换 `{{...}}` 占位 → 存为 `<工作目录>/codex-review-prompt.md` → 用 `codex --search exec ...` 喂给 CodeX（`--search` 必须在顶层）。
>
> **评审对象三选一**（决定保留/删除哪些段落）：
> - **A. 只评审文档**（spec / 设计方案）：保留「文档评审」+「SOP 交叉验证」，删「代码评审」专属项。
> - **B. 只评审代码**（一段实现 / 一个 PR / 一组文件）：保留「代码评审」+「SOP 交叉验证」，删「文档评审」专属项。
> - **C. 评审文档 + 代码（推荐）**：全保留，重点是「文档↔代码交叉验证」。

---

You are performing a DEEP, ADVERSARIAL review. Be adversarial, not agreeable: your job is to falsify claims, not to confirm them.

IMPORTANT EXECUTION RULE: You are the external reviewer yourself. Do NOT invoke the `codex` CLI again, do NOT delegate this review to any sub-process or sub-agent, and do NOT re-launch any review workflow you find referenced in the repository or environment. Perform the entire review directly in this process and write the report yourself. (A past run recursively re-launched codex and wasted the whole round.)

## Context

- **Project**: {{项目名 + 一句话技术栈，如 "Tipsy Studio — FastAPI backend + Next.js frontend + E2B sandbox + PostgreSQL + R2/S3 object store"}}
- **Review target**: {{评审对象，如 "the design spec at specs/X/spec.md AND its referenced implementation" / "the code changes in module Y" / "the document at PATH"}}
- **What it claims to do**: {{一句话：文档/代码想解决什么问题、提了什么方案}}

## Materials to review

{{按评审对象填写——保留适用的，删掉不适用的}}

- **Document(s)**: `{{文档路径，如 specs/X/spec.md；若纯代码评审则删除此项}}`
- **Code under review**: {{代码范围，如 "files A, B, C" / "the diff of branch Z vs main" / "directory src/foo/"；若纯文档评审且文档不引用代码则删除}}
- **Key files the target references / touches** (open and verify, do NOT trust descriptions):
  - `{{关键文件 1}}`
  - `{{关键文件 2}}`
  - `{{...}}`

## How to review

### 1. Verify against the actual code (both document AND code reviews)

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

Use the **web search tool** to ground your recommendations in authoritative, current best practices. Do not rely on memory alone.

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

## Output

Write your review to: `{{输出路径，如 specs/X/codex-review.md}}`

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

Be specific and cite real code. If a claim is correct, say so with evidence. If it's wrong, prove it with the actual code. Do not pad. Every best-practice recommendation must be sourced and cross-validated against the code. **Do not change any source code — only write the review file.**
