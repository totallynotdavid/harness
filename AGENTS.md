# Working rules

## Write plainly

Use short sentences. Name the subject. Cut filler and repeated context.
Prefer direct code and direct prose.

## Work

Investigate the repository, its history, and its documentation before asking
for facts they can answer. State the decision you made so it can be corrected.
Ask only when the repository cannot settle the choice.

Keep each function responsible for one thing. Keep side effects at explicit
boundaries. Put shared state behind the module that owns it. Add dependencies
through the project's package manager.

## Verify

Use the real test suite and one direct check of the behavior you changed. Show
the output that proves a failure. Treat an unverified claim as unknown.

## Comments and documentation

Comments preserve local knowledge that names and structure cannot express:
invariants, external behavior, constraints, or a non-obvious decision. They do
not narrate control flow or history.

Put workflow and subsystem explanations in the document responsible for them.
Keep one source of truth for each rule. Read rules/comments.md before a comment
cleanup and the focused document before changing a documented contract.

## Commit

Follow the repository's commit rules. Never add an AI credit, session link, or
Co-Authored-By trailer unless the repository explicitly requires it.

# Captain

This repository stores briefs, plans, reports, cases, and task records. Project
worktrees store source changes. CAP_WORK_ROOT keeps those worktrees outside this
repository so project agents do not inherit these instructions.

README.md is the operator's session guide. It owns the workflow from orientation
through delivery. This file adds the rules that an agent must load while Captain
runs that workflow.

Agents leave source changes uncommitted. Captain owns checks, commit creation,
delivery, and the decision to deliver or discard work.

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

A fix this session can specify exactly - a rename, a line-count trim, a one-line regex anchor
- does not need a dispatched agent turn to apply. Verify it directly (the check suite, a
live repro) and commit it. Reserve `cap send` for defects and design decisions that need
judgment.

A recurring defect class - the same shape of bug a gate finds twice - becomes a
deterministic static check (`tests/static/lint-*`, wired into `mise.toml`), not a second
reminder to look for it. A gate result is re-verified live (a real repro, not the diff read
again) before it is trusted, every round, since a passing round can still be wrong.

Deliver, commit, and push a task before starting the next one. Don't let a worktree sit
finished-but-undelivered while attention moves elsewhere.
