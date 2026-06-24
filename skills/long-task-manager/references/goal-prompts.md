# Goal Prompts

Use these prompts with Claude Code `/goal`.

## Recommended Autonomous Goal

```text
/goal Complete specs/<name>/task.md end to end with the long-task-manager protocol.

Maintain specs/<name>/state.md as durable memory. Use specs/<name>/verification.md as the completion gate. Keep the lead agent context short by delegating broad code search, log analysis, tests, and review to subagents.

Choose the execution mode per task:
- Main agent only for small or sequential tasks.
- Subagents for context-heavy investigation, verification, and review.
- Dynamic workflow for clearly parallelizable work.
- Agent team only for independent workstreams that require coordinated ownership.

Do not ask before choosing dynamic workflow or agent team if the choice is justified by the task structure. Before using either, update state.md, define ownership boundaries, and ensure the lead agent performs final integration and verification.

Finish only when every task is done and verification.md is satisfied, or when blockers.md records 3 failed attempts on the same blocker.
```

## Initialization-Only Prompt

Use this before starting implementation when you want to inspect the setup:

```text
Use the long-task-manager skill for specs/<name>. Initialize missing runtime files, especially state.md, decisions.md, and blockers.md. Do not implement yet. Report the initialized execution plan.
```

## Resume Prompt

```text
Use the long-task-manager skill to resume specs/<name>. Read state.md, task.md, and verification.md first. Continue from the first task not marked done. Keep state.md current and stop only when complete or blocked after 3 recorded attempts.
```

## Focused Manual Compact Prompt

Claude cannot invoke `/compact` itself through a skill. If manual compaction is needed, the user can run:

```text
/compact focus on specs/<name>/task.md, state.md, verification.md, current branch changes, remaining tasks, validation status, decisions, and blockers
```
