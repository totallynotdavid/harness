@AGENTS.md

# Captain

This repo stores briefs, plans, reports, cases, and task records. Project worktrees store
source changes. `CAP_WORK_ROOT` keeps those worktrees outside this repo so project agents
do not inherit its instructions through an ancestor directory.

Read `map.md` for the project inventory; `cap map` generates it from this
machine, so it is not tracked. Run `cap reconcile` for the current task state.
Use `cap help` for command flags. Read the focused document in `docs/` when a workflow
needs explanation.

The usual delivery path is:

1. Write a brief here.
2. Run `cap spawn` to create the worktree and start the agent session.
3. Supervise with `cap crew` and `cap watch`.
4. Run `cap check`, then `cap cleanup`.
5. Run `cap commit` and `cap land` only after the result is accepted.

Agents do not commit or deliver. The captain decides whether work lands or is discarded.
`cap check` compares tracked worktree changes with the base and lists untracked files.

For comment cleanup, read `rules/comments.md`. For commit shape, read `rules/commits.md`.
For code style, read `rules/code.md`. For gate economics and known pipeline pitfalls
(stale-base false positives, the trust-file race, session-limit recognition), read
`docs/pipeline-notes.md` before running many `cap gate` rounds on the same task.

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
