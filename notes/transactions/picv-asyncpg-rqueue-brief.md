# Swap picv-2025's compute API from psycopg/Procrastinate to asyncpg/rqueue

This is stage 1 of a 3-stage plan (you only need to do stage 1):

1. **(this task)** Swap the database driver and task queue: `psycopg` -> `asyncpg`,
   `Procrastinate` -> `rqueue`, across `packages/api`.
2. A later task retires `queue_migrate.py` in favor of rqueue's own migration
   CLI, and checks role grants for rqueue's schema.
3. A later task introduces `relq` (a typed SQL query builder, also owned by
   this account) for `compute.jobs` reads/writes and the enqueue payload,
   now that the connection is asyncpg. Do not do this now -- it depends on
   `relq`'s Python-3.13 floor work landing first, which hasn't happened yet.

You do not need to touch `relq` or wait on it. This task is a pure
driver/queue swap; nothing here requires `relq`.

## Why

`packages/api`'s `pyproject.toml` depends on `psycopg[binary,pool]` and
`procrastinate`, both entirely synchronous in this codebase. `rqueue`
(`~/git/transactions`, this account's own package, mode: local, no
external dependents yet) was purpose-built to replace Procrastinate for
exactly this application -- `REQUIREMENTS.md` §1 says so explicitly, and
even names picv-2025 as the motivating consumer. `rqueue`'s own
`queue.py` docstring literally shows `repository.create_or_get_job(...,
defer=...)` as its example usage -- this integration was designed with
this exact codebase in mind, it just hasn't been wired up.

`rqueue` requires `asyncpg` (its only runtime dependency, by design --
see `REQUIREMENTS.md` §2). It has no synchronous API and never will. So
adopting it means the parts of picv-2025 that talk to Postgres move to
asyncpg too.

Read `~/git/transactions/README.md` and `~/git/transactions/REQUIREMENTS.md`
in full before starting. Both are short and this task only makes sense in
light of them.

## Current shape (read these before changing anything)

- `packages/api/api/core/db.py` -- a process-wide `psycopg_pool.ConnectionPool`
  for API reads (`pooled()`), plus a dedicated `connect()` for the worker.
- `packages/api/api/core/repository.py` -- every function is a synchronous,
  one- or two-statement SQL call against `compute.jobs` (picv-2025's own
  table, unrelated to Procrastinate's internal tables). Uses `psycopg`
  `%s` placeholders and `Jsonb(...)` for JSON columns.
- `packages/api/api/routes.py` -- FastAPI routes are `async def`, but call
  the sync `repository` functions via `anyio.to_thread.run_sync(...)`.
  One exception: `job_events` (the SSE endpoint) already opens its own
  `psycopg.AsyncConnection` directly for `LISTEN`/`aconn.notifies(...)`.
- `packages/api/api/core/procrastinate_app.py` -- the Procrastinate `App`,
  built on `procrastinate.PsycopgConnector`.
- `packages/api/api/core/tasks.py` -- Procrastinate task definitions:
  - `enqueue_simulation(conn, compute_job_id)`: defers `run_simulation_task`
    on the caller's open connection, so the job insert and the queue insert
    commit together. This is exactly the seam `rqueue.Queue.enqueue` is
    built for -- see the docstring in `~/git/transactions/src/rqueue/queue.py`.
  - `run_simulation_task(context, compute_job_id)`: a **synchronous**
    Procrastinate task. Opens a dedicated `connect()`, fetches the job row,
    calls the CPU-bound `tsdhn.engine.run_simulation(...)` (numba-jitted,
    can run long), with an `on_progress` callback that writes progress to
    `compute.jobs` and issues `NOTIFY` on every call, all on the *same*
    connection held for the task's entire duration.
  - `reap_stalled_jobs_task` (Procrastinate `@app.periodic`, every 2 min):
    finds jobs whose Procrastinate heartbeat went stale and either retries
    or fails them. **This has no rqueue equivalent to port, and you should
    delete it, not translate it.** rqueue's `Worker._tick()` already calls
    `Storage.recover_expired_leases(...)` on every poll (see
    `~/git/transactions/src/rqueue/worker.py`), with a fencing token so a
    merely-slow (not dead) worker can't stomp on a job someone else already
    reclaimed -- exactly the gap Procrastinate has that motivated building
    rqueue in the first place (`REQUIREMENTS.md` §1, point 1). Keeping a
    hand-rolled reaper on top would be redundant and could race the
    built-in one.
  - `sweep_abandoned_work_dirs_task` (Procrastinate `@app.periodic`, hourly):
    unrelated to queue mechanics -- just deletes local work directories for
    jobs already `FAILED`. Port this one, just on whatever periodic
    mechanism you choose (see "Periodic tasks" below).
- `packages/api/api/worker.py` -- the worker process entrypoint: opens the
  Procrastinate app, calls `app.run_worker(...)`, closes on exit.

## What to do

### 1. `db.py`: asyncpg pool

Replace the `psycopg_pool.ConnectionPool` with `asyncpg.create_pool(...)`.
Decide whether the API process and the worker process should share one
pool-creation helper or keep the existing split (a pool for API reads, a
dedicated connection for the long-lived worker task) -- both are legitimate
with asyncpg; use your judgement, but document the choice in your report.

`COMPUTE_DATABASE_URL` (`postgresql://...`) is already an asyncpg-compatible
DSN; no format change needed.

### 2. `repository.py`: async + asyncpg

Every function becomes `async def`. Concretely:

- `%s` placeholders -> `$1, $2, ...`.
- `conn.execute(sql, params).fetchone()` -> `await conn.fetchrow(sql, *params)`;
  `.fetchall()` -> `await conn.fetch(...)`.
- `Jsonb(x)` -> asyncpg has no equivalent wrapper; write JSON columns as
  `json.dumps(x)` bound to a `$n::text::jsonb`-cast parameter, and read them
  back with an explicit `::text` cast in the `SELECT` list, decoding with
  `json.loads` on the way out. (`~/git/transactions/src/rqueue/storage.py`
  does exactly this, for the same reason: the caller's connection may or may
  not have a `jsonb` codec installed, and casting on both sides makes the
  behavior identical either way. Read its module docstring for the exact
  rationale, and its `_columns()` helper for the pattern.)
- **Read this carefully:** several functions currently do more than one
  statement followed by one `conn.commit()` -- e.g. `mark_started` does
  `UPDATE ...; _notify(conn, ...); conn.commit()`. That relies on psycopg's
  default (autocommit **off**), where the two statements only take effect
  together at `commit()`. asyncpg has no such implicit transaction --
  every statement commits on its own unless you open one explicitly. To
  keep "the client only ever observes the NOTIFY after the UPDATE it
  describes has committed" (the existing comment on `_notify`), wrap each
  such function's body in `async with conn.transaction():`. Check every
  function that currently ends in `conn.commit()`
  (`mark_started`, `record_progress`, `record_failure`, `fail_job`,
  `complete_job`) for this.
- `create_or_get_job` already opens its own `pooled()` + `conn.transaction()`
  block in psycopg; keep that shape, just async (`async with pool.acquire()
  as conn, conn.transaction():`). Its `defer: Any` parameter is the seam to
  a queue implementation; it should now be an async callable (`defer(conn,
  compute_job_id)` is awaited).
- `open_worker_connection`/`connect()`: replace with acquiring a connection
  from the async pool, or `asyncpg.connect(...)` directly for the worker's
  dedicated long-lived connection -- see the note about `tasks.py` below on
  why the worker connection's lifetime needs care.

### 3. `routes.py`

- Every `await anyio.to_thread.run_sync(repository.xxx, ...)` becomes
  `await repository.xxx(...)` directly, since `repository` is now async and
  routes already run on the event loop.
- `job_events` (SSE): replace the `psycopg.AsyncConnection`/`LISTEN`/
  `aconn.notifies(...)` block with asyncpg's listener API
  (`Connection.add_listener(channel, callback)`), which is callback-based,
  not an async generator. Bridge it to the existing polling-loop shape with
  an `asyncio.Queue` fed by the callback (put a sentinel on notify, drain
  and re-check job status on each tick, same keepalive/deadline logic as
  today). Keep the existing behavior: re-read job status on every wakeup
  (a notification races the wait) and on the keepalive timeout.

### 4. `procrastinate_app.py`, `tasks.py`, `worker.py`: swap the queue

Replace `procrastinate_app.py`'s `procrastinate.App` with an `rqueue.Queue`
bound to an asyncpg pool, per the Quickstart in rqueue's README. Pick a
schema name that doesn't collide with `compute` (picv-2025's own schema) --
`task_queue` (rqueue's default) or another name of your choice; rqueue's
own tables must not live in `compute` (see README, "Migrations... Queue
tables live in their own schema... never in your application's business
schema").

Rewrite `tasks.py`:

- `enqueue_simulation` becomes `async def enqueue_simulation(connection,
  compute_job_id)`, calling `queue.enqueue(connection, task=...,
  payload={"compute_job_id": str(compute_job_id)}, dedupe_key=...,
  on_conflict="return_existing", ...)` -- this is close to rqueue's own
  documented example almost verbatim; read it.
- `run_simulation_task` becomes an `async def` handler registered via
  `@queue.task(name=..., retry=..., timeout=...)`, taking `(payload,
  context: TaskContext)` per rqueue's convention. Inside:
  - Fetch the job row and call the now-async `repository` functions with
    `await`.
  - The actual CPU-bound `run_simulation(...)` call must run off the event
    loop: `await asyncio.to_thread(run_simulation, ...)`. rqueue's `Worker`
    installs a bounded default executor (`install_default_executor`,
    `executor_max_workers` in `worker.py`'s constructor) specifically so
    that a plain `asyncio.to_thread(...)` call from a handler routes through
    it -- verify this by reading `worker.py` and
    `tests/test_worker_concurrency.py`, don't assume.
  - **The `on_progress` callback problem:** today it runs synchronously on
    the same thread and connection as the rest of the task. Once
    `run_simulation` runs inside `asyncio.to_thread`, `on_progress` executes
    on a worker thread, not the event loop -- it cannot `await` an asyncpg
    call directly. Bridge it with
    `asyncio.run_coroutine_threadsafe(repository.record_progress(...), loop)
    .result()`, capturing the running loop before entering the thread.
    Decide whether progress writes use the same connection the task
    fetched the job on, or a separate one from the pool -- either is
    defensible; asyncpg connections are not thread-safe, so if you keep one
    connection for the task's duration, all uses of it (from the callback,
    via the bridge) still execute on the event loop thread one at a time,
    which is safe; just don't hand the raw connection object across threads
    without going through the bridge.
  - Retries: rqueue's `RetryPolicy`/`retry=` replaces
    `TRANSIENT_RETRY`/`RetryStrategy`. Only `TransientInfraError` should be
    retried, matching today's `retry_exceptions=(TransientInfraError,)` --
    check how rqueue expresses "retry this exception type, not that one" (it
    may be "retry unless the handler raises a non-retryable marker" rather
    than an exception allowlist; read `retry.py` and `errors.py` rather than
    guessing).
  - Delete `reap_stalled_jobs_task`, `reap_action`, `ReapAction`,
    `STALLED_HEARTBEAT_SECONDS`, `CRASH_REQUEUE_DELAY_SECONDS`,
    `CRASH_BUDGET_EXHAUSTED_ERROR`, `_fail_exhausted` -- superseded by
    rqueue's built-in lease recovery, as explained above.
  - Port `sweep_abandoned_work_dirs_task` onto whatever periodic mechanism
    you choose. rqueue has a `Scheduler`/`ScheduleSpec` module
    (`~/git/transactions/src/rqueue/scheduler.py`) with cron-like
    scheduling -- read it and decide whether to use it here, or whether a
    plain `asyncio` loop in the worker process is more appropriate for a
    single, simple, non-job-producing housekeeping sweep. Either is
    defensible; state which you picked and why.

Rewrite `worker.py`'s `main()` to run an asyncio event loop that creates the
pool, builds the `Queue`, constructs an `rqueue.Worker`, and calls `await
worker.run()` (see rqueue's README/Quickstart for the exact shape), closing
the pool on exit. Keep the existing `numba.set_num_threads(...)` setup logic
(unrelated to the queue swap).

### 5. Do not touch (out of scope for this task)

- `queue_migrate.py`, `migrate.py`, `web_grants.py` -- one-shot deploy-time
  CLI scripts, not on any request/worker hot path. `queue_migrate.py`
  specifically installs Procrastinate's schema and will need to be replaced
  by rqueue's own migration CLI, but that's stage 2's job (it also needs to
  decide what happens to already-deployed Procrastinate schemas/data, which
  this task should not have to reason about). Leave all three files alone,
  even though `queue_migrate.py` will become dead code after this lands --
  say so plainly in your report rather than deleting it yourself.
- `relq` -- not used here at all. Don't add it as a dependency.
- `compute.jobs`' own schema/DDL (`api/core/schema.py`) -- unchanged; only
  how it's read/written changes.

## Dependencies

Add `asyncpg` to `packages/api/pyproject.toml` via `uv add` (not a
hand-edit). `rqueue` is not on PyPI yet (still pre-release, mid-review in
its own repo, mode: local -- no GitHub remote to point a git dependency at).
Add it instead as a `uv add` **path** dependency pointing at the local
checkout (`~/git/transactions`), the same way a workspace member would be
added, since both repos live on this machine and neither is published yet.
State clearly in your report that this is a local, machine-specific
dependency that will need to become a real version pin once `rqueue` is
released -- don't try to solve that here.

Remove `procrastinate` from `packages/api/pyproject.toml`. Check whether
`psycopg[binary,pool]` can also be removed as a *direct* dependency of
`packages/api` or must stay because `migrate.py`/`web_grants.py`/
`queue_migrate.py` still import it directly (they do, per "do not touch"
above) -- if those three files import `psycopg` themselves, the dependency
must stay declared; don't remove a dependency three untouched files still
use just because the hot path no longer needs it.

Confirm the resulting `requires-python` in both packages is compatible:
`rqueue` requires `>=3.13`; `packages/api/pyproject.toml` currently requires
`>=3.14`, which already satisfies that -- no floor change needed here.

## Tests

Existing tests that stub or assert against `psycopg`/Procrastinate
behavior (`tests/test_db.py`, `tests/test_jobs.py`,
`tests/test_repository_integration.py`, `tests/test_tasks.py`,
`tests/conftest.py`, parts of `tests/test_api.py`) will need real rewriting
to asyncpg/rqueue fixtures, not light edits -- expect this. Breaking
changes here are expected and pre-approved; do not contort the design to
keep an old test passing. Rewrite what needs rewriting so the suite
actually exercises the new code path with a real PostgreSQL database
(these tests already use one; keep that -- don't introduce mocks for
what a real database can verify).

## Verification

Run the full `packages/api` test suite against a real PostgreSQL instance
(check `tests/conftest.py`/CI config for how one is provisioned locally).
Also do at least one direct, non-test check: start the worker and API
process by hand against a real database, submit a job through `POST
/api/v1/jobs`, and confirm it runs to completion and the SSE endpoint
reports it -- state plainly if you could not do this and why.

## Deliverable

Leave changes uncommitted. Write a report to
`~/git/captain/notes/transactions/picv-asyncpg-rqueue.md` (new file)
covering: every design decision called out above with "use your judgement"
(pool-sharing shape, progress-callback bridging, periodic-task mechanism,
retry-exception mapping), what you deleted and why, and your verification
results. If something in this brief turns out to be wrong once you're
looking at the real code (an API that doesn't exist, a signature that
doesn't match), say so plainly with the concrete evidence rather than
forcing a mismatched design through.
