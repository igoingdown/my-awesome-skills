# Task Protocol

`task.md` is the progress source of truth. Preserve its existing structure when possible.

## Status Values

Use these status values:

- `pending`: not started
- `in_progress`: currently being worked
- `done`: completed and verified
- `done_with_concerns`: functionally complete, with documented residual risk
- `blocked`: cannot continue after 3 concrete failed attempts

## Before Editing

For each task:

1. Mark it `in_progress`.
2. Add or update the current focus in `state.md`.
3. Identify likely files and existing patterns.
4. Delegate broad search or large-file reading to subagents when useful.

## After Editing

Before marking a task complete:

1. Run the relevant checks from `verification.md`.
2. Record command results in `state.md`.
3. Record decisions in `decisions.md` if the implementation made a meaningful tradeoff.
4. Record unresolved risks near the task if status is `done_with_concerns`.

## Done Criteria

Use `done` only when:

- code or docs were changed as required;
- acceptance criteria are met;
- relevant verification passed;
- no known task-specific blocker remains.

Use `done_with_concerns` only when:

- the task is practically complete;
- remaining risk is explicit and acceptable;
- verification status is documented.

Use `blocked` only when:

- the same blocker has failed after 3 concrete attempts;
- each attempt is recorded in `blockers.md`;
- no meaningful progress is possible without user input or external state change.
