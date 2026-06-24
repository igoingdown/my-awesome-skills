# Runtime State Templates

Create these files in the task directory when they are missing. Replace `<name>` and paths with the actual task directory.

## state.md

```md
# Long Task State

Status: not_started
Current task: none
Last updated: <timestamp>

## Objective

<One concise paragraph summarized from task.md and plan.md.>

## Source Files

- spec: specs/<name>/spec.md
- plan: specs/<name>/plan.md
- tasks: specs/<name>/task.md
- verification: specs/<name>/verification.md

## Completed Tasks

None.

## Current Focus

None.

## Active Files

None.

## Decisions

None yet. See decisions.md.

## Validation

Not run yet.

## Blockers

None. See blockers.md.

## Resume Instructions

On resume or after compaction:
1. Read this file.
2. Read task.md.
3. Read verification.md.
4. Continue from the first task not marked done.
```

## decisions.md

```md
# Decisions

No decisions recorded yet.
```

When recording decisions later, use:

```md
## <timestamp> - <short title>

Decision:
Reason:
Alternatives considered:
Impact:
```

## blockers.md

```md
# Blockers

No blockers recorded yet.
```

When recording failed attempts later, use:

```md
## <timestamp> - <task id>

Attempt:
Observed failure:
Hypothesis:
Next step:
```
