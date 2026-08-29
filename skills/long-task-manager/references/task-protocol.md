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

## Status Hygiene

The task list is user-visible. Every entry's status is a claim the user reads and acts on, and stale entries get challenged: "are these two really still running? why are they hanging?", "why does it still show one task open?" (asked twice, because the first answer fixed nothing), "is that task still alive? is it doing anything?".

- Mark `done` in the same turn the verification passes. Do not batch status updates to the end of the session — a task whose work shipped hours ago but still displays open reads as either unfinished work or a lie.
- An `in_progress` entry must map to a live worker (subagent, workflow, background process) that is actually producing output. When the worker finishes or dies, reconcile immediately: `done`/`done_with_concerns` if its output was accepted, `pending` or `blocked` otherwise. Never leave a zombie `in_progress`.
- On resume after compaction or interruption, reconcile the whole list against `state.md` and actual artifacts before continuing. Completions from just before the break are the ones most often left unmarked.
- When the user questions a status, verify against evidence (worker attached, artifact growth, last output time) and correct the list in the same reply. Answering the question while leaving the stale display in place is the observed failure — the user has to ask again.
