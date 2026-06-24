# Recovery Protocol

Use this after compaction, resume, interruption, agent restart, or stale context.

## Required Reload

Read these first:

1. `state.md`
2. `task.md`
3. `verification.md`

Then read targeted sections of:

4. `plan.md`
5. `spec.md`

Do not read the whole spec unless the current task requires it.

## Resume Steps

1. Identify `Current task` from `state.md`.
2. Cross-check `task.md` for the first task not marked `done`.
3. If they disagree, trust `task.md` and update `state.md`.
4. Inspect `git status` and relevant diffs before editing.
5. Continue from the smallest safe next step.

## State Repair

If `state.md` is stale but `task.md` is clear:

1. Rebuild `Completed Tasks` from `task.md`.
2. Set `Current task` to the first non-done task.
3. Record the repair in `decisions.md`.

If both `state.md` and `task.md` are unclear, stop and ask for clarification. Do not guess completion.

## Compact Reminder

Claude Code `/compact` is a CLI command, not a skill. The agent cannot invoke it through the Skill tool.

If the user asks for manual compaction instructions, recommend:

```text
/compact focus on specs/<name>/task.md, state.md, verification.md, current branch changes, remaining tasks, test status, and blockers
```
