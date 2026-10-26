# 汇总路（交叉验证）指令模板

> 用法：所有分路都 ok 之后，复制本模板 → 替换 `{{...}}` 占位 → 把**全部分路报告全文**和**原材料**贴进对应段落 → 存为 `<轮次目录>/codex-review-prompt-summary.md` → `scripts/run-one.sh <轮次目录> summary pack` 启动。产物是 `codex-review-summary.md`，它是本 Agent 逐条复核的对象。
>
> 原材料太大放不下时（单路 prompt 不超过 996,000 字符），只放各分路 finding 引用到的那些材料段，并在「Original materials」开头列出删掉了哪些。prompt 里保留下面这句要求：依赖被删材料才能裁决的 finding 标「待证」，不许凭分路报告的转述直接定案。

---

You are the SUMMARY reviewer of a multi-track adversarial review. {{N}} independent reviewers each examined one slice of the same target. Your job is to cross-validate their findings against the original materials and produce ONE merged, adjudicated review. Be adversarial toward the track reports too: a finding is not true because a track said it, and not true because several tracks said it.

IMPORTANT EXECUTION RULE: Do NOT invoke the `codex` CLI, do NOT delegate to any sub-process or sub-agent. Do the whole job in this process. Parallelize reading and checking inside this process and converge fast, without trading away evidence.

## Context

- **Review target**: {{评审对象，一句话}}
- **What it claims to do**: {{一句话}}
- **Tracks**: {{逐路列出：路名 + 分面，如 "chain: end-to-end flow & blast radius; numbers: every figure re-derived; web: external SOP evidence"}}

## Track reports

{{每份分路报告全文，用 `=== BEGIN TRACK <路名> ===` / `=== END TRACK <路名> ===` 包起来}}

## Original materials

{{原材料，用 `=== BEGIN <材料编号> <来源> ===` / `=== END <材料编号> ===` 包起来；cite evidence as `<材料编号>:<行号>`}}

{{有删减时加：Some materials were omitted for size: <列表>. If adjudicating a finding requires an omitted material, mark it "pending: material omitted" instead of deciding from the track report's paraphrase.}}

## What to do

1. **Deduplicate**: merge findings that describe the same problem into one entry, and list which tracks raised it.
2. **Adjudicate conflicts**: where tracks disagree (one says correct, another says broken; different severities; different root causes), go back to the original materials and decide. State the evidence for your ruling.
3. **Verify single-track findings**: a finding raised by only one track must be checked against the materials. Keep it, downgrade it, or reject it with evidence. Do not drop it just because others did not mention it, and do not accept it just because nobody contradicted it.
4. **Check the coverage gaps**: list anything in the target that no track examined, if it matters for the verdict.
5. **Grade uniformly** (BLOCKER / MAJOR / MINOR / NIT) and give one overall verdict.
6. **Sources**: keep every SOP/source URL the tracks cited, and flag any that look unverifiable.
7. **needs-source items**: tracks without live search mark claims "needs-source". For each one, either find an authoritative source yourself (if you have search) and cite it, or downgrade the claim to an opinion / pending item, and say how it affects the verdict. List them in a separate section.

## Output

Output the complete merged review as your **final message** (the launcher captures it with `-o`). Do not write any file. Structure:

- **Verdict**: yes / yes-with-changes / no
- **Findings**, most severe first. Each: severity; the claim or code location; which tracks raised it; your adjudication with evidence (`<材料编号>:<行号>`); why it matters; concrete fix; source URL if it invokes an SOP.
- **Rejected or downgraded track findings**: each with the track name and the evidence that overturned it.
- **needs-source items**: each with the resolution (sourced / downgraded / pending).
- **Coverage gaps**: what no track examined.
- **Sources cited**: consolidated URL list.
- **What the target got right**.
- **Open questions** that must be answered before implementation / merge.

The very last line of your final message must be exactly:

```
END_OF_REVIEW
```
