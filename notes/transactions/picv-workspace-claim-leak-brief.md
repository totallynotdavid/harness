# Fix two workspace-claim leaks in picv-2025's compute worker

This is a small, focused follow-up stacked on top of the `picv-asyncpg-rqueue-v2`
task, which migrated `packages/api`'s compute worker from psycopg/Procrastinate
to asyncpg/rqueue. That migration introduced a per-attempt filesystem lock
(`flock`) on each simulation's work directory, in `packages/api/api/core/tasks.py`.
Read that file's module docstring and the docstrings on `WorkspaceClaim`,
`claim_workspace`, and `remove_workspace` first — they explain the whole
design: `asyncio.to_thread`'s underlying OS thread cannot be killed and
outlives cancellation of the coroutine awaiting it, so a "cancelled" attempt's
kernel thread can keep running and writing into a workspace a replacement
attempt has started reusing. The `flock` exists to fence that.

A review round after that lock was added found two real leaks in it. Fix both.
Do not touch anything else — the rest of that migration has already been
through many review rounds and is considered settled; re-litigating it is out
of scope for this task.

## Defect 1: a lost race during `claim_workspace` leaks the fd and its lock forever

In `run_simulation_task`:

```python
held, resume = await asyncio.to_thread(
    claim_workspace, work_dir, context.attempt
)
claim = held
```

If the coroutine awaiting this is cancelled *after* the background thread has
already run `claim_workspace` to completion (acquired the flock, built the
`WorkspaceClaim`) but *before* `held, resume = ...` assigns the result, the
`CancelledError` propagates without `claim` ever being set. The `finally:
if claim is not None: claim.release()` block at the bottom of
`run_simulation_task` then never runs for that claim. The already-open fd,
and the `flock` held against it, are never released — nothing in this process
will ever be able to claim that workspace again, and the leak lasts for the
life of the worker process.

Separately, inside `claim_workspace` itself, if `os.ftruncate(fd, 0)` or
`os.write(fd, ...)` raises `OSError` *after* `fcntl.flock` has already
succeeded, nothing closes `fd` — only the flock-acquisition line itself is
wrapped in `try/except OSError` with a matching `os.close(fd)`.

Fix both leak paths. Think about where the responsibility for "this fd must be
closed no matter what happens after it's opened" belongs — a thread that
successfully acquires the lock should hand back something that reliably gets
released even if the coroutine on the other end of `asyncio.to_thread` never
gets to receive it normally.

## Defect 2: a completed job's workspace can leak permanently if cleanup loses the race

`remove_workspace` (already correctly written to avoid the classic
`flock`+`unlink` footgun) returns `bool` — whether it actually removed the
workspace, or backed off because something still holds the lock. Two call
sites ignore that return value:

- The success path at the end of `run_simulation_task`:
  `await asyncio.to_thread(remove_workspace, work_dir)`
- The redelivered-and-already-completed path in `_stand_down`:
  `await asyncio.to_thread(remove_workspace, work_dir)`

If `remove_workspace` returns `False` at either site (a zombie thread from an
earlier, since-abandoned attempt is still mid-write and holds the lock), the
workspace is never retried. `sweep_abandoned_work_dirs` — the only other
thing that ever calls `remove_workspace` — only looks at jobs whose
`compute.jobs.status` is `failed` (see `list_abandoned_work_dirs` in
`repository.py`). A workspace belonging to a `completed` job that lost this
race has no path back to cleanup at all: it leaks on disk permanently.

Fix this so a completed job's workspace that fails to remove gets retried
later, the same way a failed job's does. Decide on merit: you could widen what
the sweep considers ("failed or completed, past the TTL"), or handle the
retry closer to where the removal is attempted, or something else — pick
whichever fits the existing design most cleanly, and say why in the report.

## Already settled — do not re-investigate or re-fix

A prior review round raised, and this task's predecessor already resolved
with documented reasoning (see `notes/transactions/picv-asyncpg-rqueue-v2.md`
in this repo for the full history):

- `mark_started` allowing a `failed` row to be reclaimed, and `complete_job`
  having no terminal-status guard, are both intentional — a genuine result is
  allowed to overwrite reconciliation's heuristic guess, and `Admin.retry_job`
  depends on `failed` being reclaimable. Gate reviewers have repeated this
  finding several rounds running; it is settled. Do not touch it.
- The Procrastinate-to-rqueue data migration (no existing deployment has any
  `procrastinate_jobs` rows to migrate) is settled and out of scope.
- The graceful-shutdown/retry-budget interaction (a long-running step can hold
  the workspace lock past a SIGTERM, in theory costing an attempt or two) is a
  disclosed, accepted trade-off. Leave it as documented.

## Verification

Run the same bar the rest of this migration was held to:
- `mypy --strict packages/api`, `ruff check` (repo's full ruleset)
- The fast test suite, and the integration suite against a real Postgres
  database (see `packages/api/tests/conftest.py` for how other integration
  tests in this codebase stand one up)
- Add tests that actually exercise both leaks: one that reproduces the
  lost-race fd leak (or demonstrates it's now impossible), and one that
  exercises a completed job's workspace surviving a failed removal and later
  succeeding.

## Report

Append a new dated section to `notes/transactions/picv-asyncpg-rqueue-v2.md`
in this repo (the running report for the parent task) rather than starting a
fresh report file, so the whole history of this migration stays in one place.
Do not commit. Leave changes uncommitted in the worktree.
