# Delegation Policy

The lead agent owns planning, edits, integration, state files, and final acceptance. Delegation is for context control and parallel analysis.

## Default Mode

Default to:

```text
lead agent + focused subagents
```

The lead agent should write the final code unless the work units are clearly non-overlapping.

## Use Subagents For

- broad codebase search
- reading large files
- summarizing long logs
- analyzing test failures
- independent risk review
- checking task acceptance
- identifying existing patterns

Subagent output must be concise:

```text
Findings:
- ...

Relevant files:
- ...

Recommended change:
- ...

Risks:
- ...
```

Do not ask subagents to paste full logs, full files, or speculative essays.

## Use Dynamic Workflow When

Use dynamic workflows only when work is clearly parallelizable, such as:

- independent frontend/backend/test tracks
- repository-wide audits
- migrations touching many independent files
- independent bug hypotheses
- broad verification work

Before starting:

1. Update `state.md`.
2. Define work units.
3. Define ownership boundaries.
4. Define merge and verification rules.
5. Keep the lead agent responsible for synthesis.

Avoid dynamic workflows when:

- edits target the same files;
- the task is sequential;
- the task is small;
- the integration risk is higher than the parallelism benefit.

## Use Agent Teams When

Agent teams are optional and experimental. Use them only when multiple agents need coordinated ownership or direct communication across independent workstreams.

Good fit:

- one teammate owns backend, one owns frontend, one owns verification;
- teams need to coordinate API contracts;
- long independent workstreams can run concurrently.

Poor fit:

- same-file edits;
- small bug fixes;
- sequential migrations;
- tasks where subagents returning summaries are enough.

If using agent teams, require:

- named teammates;
- non-overlapping ownership;
- explicit quality gates;
- final synthesis by the lead agent.
