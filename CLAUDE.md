@AGENTS.md

# Captain

This repository stores briefs, plans, reports, cases, and task records. Project
worktrees store source changes. CAP_WORK_ROOT keeps those worktrees outside this
repository so project agents do not inherit these instructions.

The operator's session is:

1. Orient from the project map and current task state.
2. Write a brief with an outcome and evidence.
3. Dispatch the task into an isolated project worktree.
4. Supervise the session and inspect its output.
5. Check, verify, and review the result.
6. Commit and land only after the result is accepted.

Agents leave source changes uncommitted. Captain owns checks, commit creation,
delivery, and the decision to land or discard work.

Read docs/operations.md when a gate, check, session, quota reading, or queued
message behaves unexpectedly. Read docs/architecture.md for state ownership and
module boundaries. Read docs/commands.md for command flags.

Read rules/comments.md for comment cleanup, rules/commits.md for commit shape,
and rules/code.md for code structure.

## Delivery economics

Hardening Captain itself competes with every project for the same window. A harness
defect that only shows up in an edge case is worth a direct fix or a `paper-cuts.md` entry,
not a multi-round gated task, unless it is actively blocking delivery right now. Default to
project work; treat Captain's own pipeline as background maintenance.

A fix a captain can specify exactly - a rename, a line-count trim, a one-line regex anchor
- does not need a dispatched agent turn to apply. Verify it directly (the check suite, a
live repro) and commit it. Reserve `cap send` for defects and design decisions that need
judgment.

A recurring defect class - the same shape of bug a gate finds twice - becomes a
deterministic static check (`tests/static/lint-*`, wired into `mise.toml`), not a second
reminder to look for it. A gate result is re-verified live (a real repro, not the diff read
again) before it is trusted, every round, since a passing round can still be wrong.

Land, commit, and push a task before starting the next one. Don't let a worktree sit
finished-but-undelivered while attention moves elsewhere.
