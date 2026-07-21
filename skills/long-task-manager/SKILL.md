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
  plan.md
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

## Startup Protocol

1. Read `task.md`, `state.md`, and `verification.md`.
2. Read targeted sections of `plan.md`.
3. Do not read full `spec.md` unless the current task requires it.
4. Identify the first task not marked `done`.
5. Update `state.md` with the current task before editing.

If `state.md` is missing, initialize `state.md`, `decisions.md`, and `blockers.md` first. Do not ask the user to create them manually.

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

## Stall and Oversized-Document Policy

Two failure modes observed in real long runs:

- **Stalled background work.** A subagent, workflow, or background task that loops on API retries or network errors is not making progress. Do not wait indefinitely: if the same unit shows repeated retries with no new output, stop it, record the attempt in `blockers.md`, and restart it from durable state. Durable files make restarts cheap; silent waiting is the expensive option.
- **Oversized working documents.** If `plan.md` or an implementation plan grows so large that re-reading it every cycle overflows the context (symptom: forced compaction or API retry loops on every cycle), split it: one file per task plus a short index, and load only the current task's file. Do not keep growing a single monolithic plan document.

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

## Completion Criteria

The long task is complete only when:

- every task in `task.md` is `done` or explicitly accepted as `done_with_concerns`;
- `state.md` says no active task remains;
- required checks in `verification.md` passed, or failures are documented as unrelated/pre-existing;
- the final response includes changed files, validation results, and residual risks.

## Goal Prompt

When the user asks how to combine this skill with Claude Code `/goal`, use `references/goal-prompts.md`.
