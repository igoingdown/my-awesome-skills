---
name: long-task-manager
description: Use when running long Claude Code implementation tasks from large spec, plan, task, and verification documents. Initializes durable state.md, manages progress, delegates context-heavy work to subagents or dynamic workflows, recovers after compaction/resume, and keeps working until completion or a proven blocker.
---

# Long Task Manager

Use this skill for long-running implementation work driven by large documents.

The goal is not to preserve an unlimited chat context. The goal is to make the task durable enough that compaction, resume, or interruption cannot lose progress.

## Core Rule

Context can be compacted. Durable files are the source of truth.

- `task.md` is the progress source of truth.
- `state.md` is durable working memory.
- `verification.md` is the completion gate.
- `decisions.md` stores durable decisions.
- `blockers.md` stores failed attempts and blocker history.

Do not rely on chat history as the only record of progress, decisions, blockers, test results, or remaining work.

## Required Inputs

Find the task directory from the user request. Preferred layout:

```text
specs/<name>/
  spec.md
  plan.md            # or implementation.md for per-line low-level design
  task.md
  verification.md
```

If the runtime files below are missing, create them before implementation:

```text
specs/<name>/
  state.md
  decisions.md
  blockers.md
```

Use `references/state-template.md` for the initial contents.

## Document Layering

Keep two design layers separate instead of merging them into one document:

- **spec.md** — coarse-grained design: background, goal, constraints, risks, approach, impact, ROI. It also indexes the implementation chapters.
- **implementation.md** (or `impl-plan.md`) — low-level design: which files change, which lines change, why, and the observability added with the change.

Do not collapse the two. The spec is what you align with the requester and review before work starts; the implementation is what you review line by line before editing code. When asked what the difference is, answer by granularity and audience, not by file name.

If the implementation grows large, split it into chapters and have the spec list them. See the oversized-document policy below.

## Startup Protocol

1. Read `task.md`, `state.md`, and `verification.md`.
2. Read targeted sections of `plan.md`.
3. Do not read full `spec.md` unless the current task requires it.
4. Identify the first task not marked `done`.
5. Update `state.md` with the current task before editing.

If `state.md` is missing, initialize `state.md`, `decisions.md`, and `blockers.md` first. Do not ask the user to create them manually.

When the request names a directory rather than a single file (for example "the files under `implementation/`"), enumerate that directory and read every file in it before reporting the plan. Sampling a few and inferring the rest produces a plan with holes, and the user will ask "are you sure you read all of them?" — which means the answer must already be yes. If the set is too large for one context, delegate the reading to subagents per file and merge their summaries; state the file count you covered.

## Alignment Gate

When the user asks to initialize a plan, investigate, or design without implementing, stop at the plan. Report the execution plan and wait.

Treat these as explicit alignment requests: "do not implement yet", "let's align first, then take the next step", "don't touch the document yet, tell me how you plan to change it".

Restate the request before proposing anything. The user asks for the same six-part restatement almost every time a new task starts, and asks for it again when a proposal misses the point: **requirement, goal, constraints, rough approach, risks, blast radius**. Write those six explicitly, in that order, and put what you are *not* going to do next to the blast radius. This is where a misread surfaces cheaply — a proposal that hangs the change off the wrong layer (a generic middleware instead of the specific path the task is about) reads as plausible until the six parts are written out and the constraint it violates becomes obvious. When the user says the plan is wrong and asks you to re-derive the requirement, redo all six from scratch rather than patching the previous proposal.

Under an alignment request:

- Investigate the chain end to end first: where the code actually does the thing, which branches and bypass paths exist, which caches or invalidation rules are involved. Report unknowns as unknowns.
- Present the options with tradeoffs and a recommendation. Do not start editing the chosen one until the user picks.
- Ask the open questions instead of guessing. The user has repeatedly invited questions at this stage; asking is cheaper than reworking.

Once the user picks an option, implement that option. Do not re-open the comparison.

### When the restatement is asked for again in the same session

On a hard task the user will ask for the restatement five or six times in one sitting, each time adding a clause. That is not ritual — each re-ask means the previous one left something unanchored, and the added clause names it. Observed escalation, in the order it arrives: the six parts → the option set per problem with cost/risk/benefit each → the quantitative evidence behind each option → the decision tree and whether it is exhaustive and non-overlapping → blast radius, effort, and ROI per option.

- **Answer the escalation, do not re-send the previous restatement with edits.** Re-asked means re-derive. If a part is genuinely unchanged, say so in one line and spend the space on the new clause.
- **Every decision node needs a quantitative fact under it, or an explicit "not measured yet".** A tree whose branches are justified by plausibility reads complete and is not; the user asks "what quantitative data supports each choice" precisely to find those nodes. Name the measurement (what was counted, over what window, how many samples) or mark the node unmeasured and say what would measure it.
- **Claim exhaustive/non-overlapping only after enumerating from the code**, not from the shape of the tree. "Are the branches complete? Is anything missing?" is answerable only by walking the actual branch points in the implementation. If a branch cannot be distinguished with available data, that is a hole — state it rather than folding it into a neighbour.
- **Carry forward everything the user has supplied.** Each round they correct a fact or answer an open question; the next restatement must contain those answers, attributed to them. Re-asking a question they already answered, or restating a premise they already overturned, is what triggers the next re-ask.
- **When they say a proposal is not OK, take the counter-proposal as the new baseline.** They will describe an alternative in their own words and ask "did you understand my approach? restate it". Restate their approach, not a defence of yours, and mark where it changes constraints you had assumed.

An answer that cannot yet be given is a legitimate part of the restatement: list what you still need to investigate and what you need from the user, then continue. Silence on an unknown reads as a covered base.

## Execution Loop

For each task:

1. Mark the task `in_progress`.
2. Inspect relevant code before editing.
3. Delegate context-heavy investigation to subagents when useful.
4. Implement the smallest coherent change.
5. Run task-specific checks from `verification.md`.
6. Fix failures caused by the change.
7. Update `state.md`.
8. Mark the task `done`, `done_with_concerns`, or `blocked`.
9. Continue automatically to the next task.

Use `references/task-protocol.md` for task status rules.

## Context Control

Keep the lead agent's context short.

Use subagents for:

- broad codebase search
- reading large files
- test failure analysis
- log analysis
- independent code review
- spec-to-code mapping
- risk review

Ask subagents to return concise structured summaries only. Do not let subagents paste full logs or large file contents into the lead agent context.

Use `references/delegation-policy.md` before choosing subagents, dynamic workflows, or agent teams.

## Dynamic Workflow and Agent Team Choice

Default to the lead agent plus focused subagents.

Choose the execution mode per task:

- Lead agent only for small or sequential tasks.
- Subagents for context-heavy investigation, verification, and review.
- Dynamic workflow for clearly parallelizable work.
- Agent team only for independent workstreams that require coordinated ownership.

Before using a dynamic workflow or agent team:

1. Update `state.md`.
2. State why that mode is justified.
3. Define non-overlapping work units.
4. Define merge, verification, and conflict-resolution rules.
5. Keep the lead agent responsible for final synthesis and acceptance.

Do not use dynamic workflows or agent teams for small, sequential, same-file, or tightly coupled changes.

## Recovery Protocol

After compaction, resume, interruption, or stale context:

1. Read `state.md`.
2. Read `task.md`.
3. Read `verification.md`.
4. Continue from the first non-done task.
5. Read only the necessary sections of `plan.md` or `spec.md`.

Use `references/recovery-protocol.md` for exact recovery steps.

## Scope Reduction Policy

Dropping or simplifying part of an agreed plan is a decision, not an implementation detail.

Observed failure: a design element the user had approved quietly disappeared from a later revision, and the user had to ask "why is this gone, and when did I ever decide that?". Silent scope loss is worse than an open disagreement, because it hides from review.

When a task, field, or mechanism from the aligned spec is dropped or downscoped:

1. Record it in `decisions.md` with attribution: who decided (user or agent), when, and the reason.
2. If the agent decided, say so explicitly. Never present an agent-side simplification as a prior user decision.
3. Flag it in the response that carries the revision, not only in the file.
4. If the drop touches something the user explicitly asked for, ask before revising instead of revising and reporting.

When the user asks "why was X removed", answer with the recorded decision (time, decider, reason). If there is no record, say that plainly — no reconstructed rationale.

## Handoff Protocol

Work discovered mid-task that is real but out of scope does not belong to the current task. Split it out into a handoff document and let a separate session pick it up.

Observed pattern: the user repeatedly asked for a side issue to be written up as a handoff document to follow up separately, then started a fresh session or worktree from that file alone. The handoff file was the only context that survived.

A handoff document must stand alone, because its reader has none of this session's context:

- background and goal, one paragraph;
- the symptom, and what is already proven versus still hypothesis, each with its evidence source;
- the files, functions, and configuration involved;
- options considered and any decision already made, with attribution;
- the concrete next step;
- how the fix will be verified.

Record the split in `decisions.md` and say in the response that the item left the current task. Do not silently keep it on the current task list.

When asked to continue from a handoff document, treat it like a spec: read it first, initialize missing runtime files, and re-verify its claims against current code before implementing — a handoff written days ago may describe code that has since changed. Prefer a separate worktree for the split-out work so the two lines of change cannot collide.

A handoff only counts once it is on disk. Write the file, then report its absolute path in the same response, so the next session can start from it. A handoff that exists only as chat text is lost at the session boundary — observed failure: the user opened a fresh session pointed at a handoff path that was never written, and the follow-up work had no context to start from.

If a handoff path you are asked to continue from does not exist, say so and stop. Do not reconstruct a plausible handoff from memory and proceed as if it were the original: locate the real surviving artifacts (design docs, task directories, prior branches), list what you found, and ask which one to continue from. Reconstruction silently substitutes your guess for the previous session's decisions.

## Stall and Oversized-Document Policy

Two failure modes observed in real long runs:

- **Stalled background work.** A subagent, workflow, or background task that loops on API retries or network errors is not making progress. Do not wait indefinitely: if the same unit shows repeated retries with no new output, stop it, record the attempt in `blockers.md`, and restart it from durable state. Durable files make restarts cheap; silent waiting is the expensive option. Liveness is measured by output, not by process state: a unit that is "still running" while its token count, log size, and written artifacts barely move is stalled, not slow — the user has caught this by checking token consumption. When the user asks how it is going, answer with that evidence (elapsed time, output growth, current step, last artifact written), never with "still running".
- **Long batch runs with no ETA and no wake-up.** When a task fans out over a large work list (per-item model calls, per-file passes, per-user extractions), the user will ask "how is it going, and how much longer?" and then ask you to set a frequent timer that picks the next step up automatically. Both parts are on you to have already done. Report progress as **items done / items total, throughput per minute, and an ETA derived from the two** — plus what the next step is once it finishes. "Still running" and "almost done" are non-answers; if the total is genuinely unknown, say what bounds it. And do not leave a long batch waiting on the user to come back: schedule a recurring check whose interval is a small fraction of the remaining time, so the run is picked up and the next step started shortly after it finishes rather than at the next time someone happens to ask. State the interval and what the check will do when it fires.
- **Oversized working documents.** If `plan.md` or an implementation plan grows so large that re-reading it every cycle overflows the context (symptom: forced compaction or API retry loops on every cycle), split it: one file per task plus a short index, and load only the current task's file. Do not keep growing a single monolithic plan document.

## Local Verification Cost Policy

Verification steps run on a machine that is often shared and quota-limited. Before running a build, test sweep, or any step that fans out per target, estimate the fan-out and the bytes it will produce, and cap it.

- **Count the targets first.** A whole-project build in a repo with many binaries links them in parallel, each link spawning its own thread pool and re-reading the same large dependency archives. The observable result is hundreds of threads and processes stuck on IO, load in the hundreds while CPU sits idle, and the machine unusable for everyone on it for tens of minutes. Build the specific target the task needs, or pin build parallelism low, before building everything.
- **Do not read high load as high CPU.** When a verification step hangs, check the blocked-process count and disk queue depth before concluding the machine is compute-bound. Misreading saturated IO as saturated CPU sends the whole diagnosis the wrong way.
- **Reclaim on the way out.** A cold full build can consume many gigabytes of intermediate artifacts. Delete the build/link temp directories and any probe directories the task created as soon as the step finishes, and record before/after quota so the reclaim is verified rather than assumed. Do not leave cleanup to a later sweep.
- **Report a shared-resource problem with attribution, and do not clean up what you did not create.** When a check hits a machine-level limit (quota exceeded, disk full, load unusable), say so in the same response, separated into three parts: what this task consumed, what has already been reclaimed, and what the remainder is (historical accumulation, another session's artifacts, someone else's files). Deleting the remainder is not yours to do — surface it and let the user decide, even when the limit is blocking your own step. An accurate "this is not from my run, here is what is, here is what I cleaned" is more useful than either a silent cleanup or a bare "disk is full".
- Prefer a container or a scratch instance for anything that needs a real service to verify against, and destroy it when the check passes. Record in `state.md` that the step ran and was cleaned up.

Put the estimate in `state.md` before running the step, and record the actual cost after. When a verification step has to be skipped because it would not fit the machine, that is a `blockers.md` entry with the numbers, not a silent skip.

## Batch and Backfill Job Policy

A batch or backfill job — a script that fans out per-item work (per-user extraction, per-row rewrite, model calls over a candidate list) — is a long task in its own right, with its own where-to-run and de-risk decisions distinct from a one-shot build.

- **Run it where the tools and horsepower are, which is usually local, not the production pod.** The default is: anything that can run locally, runs locally. A production pod is weak, its toolchain is incomplete (no editor, missing utilities), and it is slow; running a script there because that is where the data appears to live is a false economy. Check first whether the job can reach the data from a local run (read-only DB access, an export, a data proxy) — the user's standing rule is "whatever can run locally, run locally; never on production." Only run inside the pod when the data genuinely cannot be reached from outside, and say why when you do.
- **De-risk the real run with a scaled dry-run before committing to it.** A dry-run over 5 rows proves the happy path, not the run. Before the real pass, run a dry-run large enough to surface the edge cases that only appear at scale — the input that overflows a conversion, the row that reads back empty, the record that crashes one item mid-list — and enumerate up front what else can be pre-validated (schema of the target table, a probe on the known-bad input, the resume path). "How confident are you it will complete without a mid-run crash, and what can we test before starting?" is a question to have already answered, not to be asked.
- **Confirm idempotent resume before the real run, not after a crash.** Long batches get interrupted (pod restart, network, a single bad row). Verify that a re-run skips already-done work rather than redoing or double-writing it, and that it resumes from durable state — test this on real data before the real pass, so an interruption is a resume rather than a restart. Only then launch the real run detached (e.g. `nohup`), reporting progress as items done / total, throughput, and ETA (see the batch-run bullet under Stall and Oversized-Document Policy).

## Blocker Policy

A blocker is valid only after 3 concrete attempts against the same issue.

Record each attempt in `blockers.md` with:

- timestamp
- task id
- attempted command or change
- observed failure
- hypothesis
- next step

Stop only when the same blocker has failed after 3 concrete attempts and no meaningful progress remains possible.

## Review Walkthrough Policy

When the user says they will review the change ("what changed and how? I'm going to review it"), the deliverable is a walkthrough, not a diffstat. The same asks recur across sessions in these exact shapes: "explain it with a concrete example", "walk the whole logic through one instance", and — for anything iterative — a chain of "why can't this be simpler" questions drilled down to the root cause.

- For each change: why it exists (the problem), what changed (files and behavior), then **one worked example with concrete values** traced through the main path and the key branches. An abstract description of the algorithm does not land; the same explanation with real numbers does.
- If the diff touches a file or directory outside the task's stated scope, explain why in the walkthrough before being asked. "Why did we change this path at all?" is a question the walkthrough should already answer.
- For a mechanism more complex than the obvious alternative (a convergence loop instead of a fixed pass count, a conditional reserve, a retry ladder): state the obvious alternative first and show exactly where it breaks — name the dependency cycle or the input that cannot be known up front. The user will keep asking "why not the simpler way" until the root cause is on the table, so put it there first instead of answering one layer per question.

## Completion Criteria

The long task is complete only when:

- every task in `task.md` is `done` or explicitly accepted as `done_with_concerns`;
- `state.md` says no active task remains;
- required checks in `verification.md` passed, or failures are documented as unrelated/pre-existing;
- the final response includes changed files, validation results, and residual risks.

## Goal Prompt

When the user asks how to combine this skill with Claude Code `/goal`, use `references/goal-prompts.md`.
