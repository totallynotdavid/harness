# Re-land the queue-roles/retention feature onto the current migration tip

This is a redo of the `picv-rqueue-operability` task (least-privilege rqueue
roles + retention purging for picv-2025's compute worker), which built its
feature correctly but against a now-stale snapshot of its parent task
(`picv-asyncpg-rqueue-v2`, the psycopg/Procrastinate -> asyncpg/rqueue
migration). That parent went through several more review rounds after
`picv-rqueue-operability` synced its worktree, including a whole
filesystem-locking subsystem (`WorkspaceClaim`, `claim_workspace`,
`remove_workspace` in `packages/api/api/core/tasks.py`) that did not exist yet
at sync time. `picv-rqueue-operability`'s worktree currently has that older
`tasks.py` (and older `db.py`, `repository.py`, `worker.py`, tests, and
docs) — applying its diff as-is would silently delete all of that later work.
Do not do that.

The parent has now landed as commit `27d2a3e` on branch
`cap/picv-asyncpg-rqueue-v2` (open as PR #175 against `bump`, not yet merged).
Base your work on that branch/commit, not on `bump` and not on
`picv-rqueue-operability`'s old worktree state.

## What actually needs doing

Read the full report from the original attempt first:
`notes/transactions/picv-rqueue-operability.md` in the captain repo at
`/home/dubu/git/captain` (this is a *report about your own repo*, written to
a different repo — read it with a plain file read, not from inside this
worktree). It documents the design in detail: the three roles
(`tsdhn_producer`/PRODUCE, `tsdhn_worker`/CONSUME, `tsdhn_purger`/INSPECT +
DELETE on `compute.jobs`), why retention is a third role rather than folding
DELETE into CONSUME, the 7-day retention window reasoning, the exact grant
tables, and the by-hand verification against a real database. Treat that
report as the design spec: the "what" and "why" are already settled and
reasoned through; your job is implementing that same design against the
current code, not re-deciding it.

Your own worktree is freshly checked out from the current parent tip, so it
starts clean — none of the stale-revert problem described above exists in it
yet. Two files in `picv-rqueue-operability`'s *old* worktree
(`/home/dubu/.cap-work/picv-rqueue-operability`, a separate directory, still
on disk) are genuinely new and untouched by the staleness problem — they do
not exist on the parent branch at all, so there is nothing to reconcile. Copy
them into your own worktree as a starting point, adjusting only if the
current code shape around them requires it:

- `packages/api/api/queue_grants.py`
- `packages/api/tests/test_queue_roles_integration.py`

Everything else that worktree's `git diff HEAD` shows as *modified* (`db.py`,
`repository.py`, `tasks.py`, `worker.py`, `settings.py`, `schema.py`,
`queue.py`, `docker-compose.yml`, `mise.toml`, `.env.example`, `readme.md`,
`ARCHITECTURE.md`, the e2e scripts, `scripts/database.py`, and the test files
other than the new roles one) is comparing against the *old* stale base and
must not be trusted or copied wholesale. Start those files from the current
`cap/picv-asyncpg-rqueue-v2` tip and re-add only the operability-specific
pieces on top: role-scoped connection/DSN support in `db.py`, the retention
purge periodic task (worker-side, its own small pool as the `tsdhn_purger`
role), the settings for the three roles' passwords/DSNs, the
docker-compose/mise/`.env.example` wiring for those three new required
passwords, the schema/grants side of provisioning, and the readme/architecture
doc updates specific to roles and retention. Use the old diff as a reference
for *intent* (what changed and why, per the report), not as a patch to apply.

## Verification

Same bar as the rest of this migration:
- `mypy --strict packages/api`, `ruff check`
- Fast test suite, and the integration suite against a real Postgres database
  — including `test_queue_roles_integration.py`'s real-role privilege checks
- Confirm nothing in the workspace-locking subsystem
  (`claim_workspace`/`WorkspaceClaim`/`remove_workspace`, the `owner_attempt`
  fencing, the SQLSTATE-class transient-error classification) regressed —
  diff your final `tasks.py`/`db.py`/`repository.py` against
  `cap/picv-asyncpg-rqueue-v2`'s versions and confirm the only differences are
  the operability additions, not reverted fixes.

## Report

Append a new section to `notes/transactions/picv-rqueue-operability.md` in
`/home/dubu/git/captain` (not this repo) explaining what was resynced and how
you verified nothing regressed. Do not commit. Leave changes uncommitted.
