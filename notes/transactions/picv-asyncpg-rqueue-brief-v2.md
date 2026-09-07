# Swap picv-2025's compute API from psycopg/Procrastinate to asyncpg/rqueue

## Read this first: a prior attempt on the wrong base branch

A previous run of this task was spawned against picv-2025's `master`
(stale, 44 commits behind, no bump-branch content) instead of `bump` (the
actual active branch, and this task's real base). Its report,
`~/git/captain/notes/transactions/picv-asyncpg-rqueue.md`, is nonetheless
genuinely useful: everything in it about **rqueue itself** was independently
verified against rqueue's real source and a real end-to-end run, and none of
that depends on which picv-2025 branch it's applied to. Read it. Its
"decisions the brief left to judgement" section (pool shape, the progress
callback bridge, dedupe key, retry mapping, queue schema, LISTEN pool-sizing
gotcha for `rqueue.Worker._listener()`) is the intended design -- reuse it,
adapted to the real files on `bump`, rather than rediscovering it from
scratch. Its "what I deleted" and dependency sections do not apply as-is
(they describe deleting things `master` didn't have and `bump` does) --
verify everything against `bump`'s actual current code instead of trusting
either document blindly.

This is stage 1 of a 3-stage plan (you only need to do stage 1):

1. **(this task)** Swap the database driver and task queue: `psycopg` -> `asyncpg`,
   `Procrastinate` -> `rqueue`, across `packages/api`.
2. A later task retires `queue_migrate.py`/legacy migration handling in favor
   of rqueue's own migration CLI, and checks role grants for rqueue's schema.
3. A later task introduces `relq` (a typed SQL query builder, also owned by
   this account) for `compute.jobs` reads/writes and the enqueue payload,
   now that the connection is asyncpg. Do not do this now.

You do not need to touch `relq` or wait on it. This task is a pure
driver/queue swap; nothing here requires `relq`.

## Why

`packages/api`'s `pyproject.toml` (on `bump`) depends on `psycopg[binary,pool]`
and `procrastinate`, both entirely synchronous in this codebase. `rqueue`
(`~/git/transactions`, this account's own package, mode: local, no external
dependents yet) was purpose-built to replace Procrastinate for exactly this
application -- `REQUIREMENTS.md` §1 says so explicitly, and even names
picv-2025 as the motivating consumer. `rqueue`'s own `queue.py` docstring
literally shows `repository.create_or_get_job(..., defer=...)` as its
example usage -- this integration was designed with this exact codebase in
mind, it just hasn't been wired up.

`rqueue` requires `asyncpg` (its only runtime dependency, by design -- see
`REQUIREMENTS.md` §2). It has no synchronous API and never will. So adopting
it means the parts of picv-2025 that talk to Postgres move to asyncpg too.

Read `~/git/transactions/README.md` and `~/git/transactions/REQUIREMENTS.md`
in full before starting.

## Current shape on `bump` (verified directly, but re-verify against your
own checkout's HEAD before changing anything -- `bump` may have moved again)

- `packages/api/api/core/db.py` -- a process-wide `psycopg_pool.ConnectionPool`
  for API reads (`pooled()`), plus a dedicated `connect()` for the worker.
- `packages/api/api/core/repository.py` -- every function is a synchronous,
  one- or two-statement SQL call against `compute.jobs` (picv-2025's own
  table, unrelated to Procrastinate's internal tables). Uses `psycopg` `%s`
  placeholders and `Jsonb(...)` for JSON columns.
- `packages/api/api/routes.py` -- FastAPI routes are `async def`, but call
  the sync `repository` functions via `anyio.to_thread.run_sync(...)`. One
  exception: `job_events` (the SSE endpoint) already opens its own
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
    rqueue in the first place (`REQUIREMENTS.md` §1, point 1).
  - `sweep_abandoned_work_dirs_task` (Procrastinate `@app.periodic`, hourly):
    unrelated to queue mechanics -- deletes local work directories for jobs
    already `FAILED`. Port this one onto whatever periodic mechanism you
    choose. The prior report's judgement (a plain `asyncio` task in the
    worker process, not `rqueue.Scheduler`, because the operation is
    idempotent and doesn't need occurrence-key exactly-once machinery) is
    sound -- reuse it unless you find a reason not to.
- `packages/api/api/worker.py` -- the worker process entrypoint: opens the
  Procrastinate app, calls `app.run_worker(...)`, closes on exit; also does
  `numba.set_num_threads(...)` setup, unrelated to the queue swap and to be
  kept.

## What to do

### 1. `db.py`: asyncpg pool

Replace the `psycopg_pool.ConnectionPool` with `asyncpg.create_pool(...)`.
The prior attempt's design (one `open_pool`/`close_pool`/`get_pool`/
`acquire()` helper shared by both the API and worker processes, sized
differently via settings) is a reasonable default -- reuse it unless `bump`'s
actual code gives you a reason to diverge. Read its "Pool shape" section for
the full reasoning, including why it did **not** keep one dedicated
long-lived connection for the worker task, and why worker pool sizing is
load-bearing for `rqueue.Worker._listener()` (it holds one connection for
the whole run to `LISTEN`; undersizing the pool makes that silently fall
back to polling).

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
  behavior identical either way.)
- Several functions currently do more than one statement followed by one
  `conn.commit()` -- e.g. `mark_started` does `UPDATE ...; _notify(conn,
  ...); conn.commit()`. That relies on psycopg's default (autocommit
  **off**), where the two statements only take effect together at
  `commit()`. asyncpg has no such implicit transaction -- every statement
  commits on its own unless you open one explicitly. To keep "the client
  only ever observes the NOTIFY after the UPDATE it describes has committed"
  (the existing comment on `_notify`), wrap each such function's body in
  `async with conn.transaction():`. Check every function that currently ends
  in `conn.commit()` (`mark_started`, `record_progress`, `record_failure`,
  `fail_job`, `complete_job`) for this. (Unlike the prior mis-based attempt,
  `bump` genuinely has `_notify`/`NOTIFY` calls in these functions -- this
  transaction-wrapping instruction applies for real here.)
- `create_or_get_job` already opens its own `pooled()` + `conn.transaction()`
  block in psycopg; keep that shape, just async. Its `defer: Any` parameter
  is the seam to a queue implementation; it should now be an async callable
  (`defer(conn, compute_job_id)` is awaited).
- `open_worker_connection`/`connect()`: replace per the pool design in
  step 1.

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
  today). Keep the existing behavior: re-read job status on every wakeup (a
  notification races the wait) and on the keepalive timeout. This is real
  work here, unlike the prior mis-based attempt where no NOTIFY existed to
  listen for -- `bump` genuinely has it, so build it for real.

### 4. `procrastinate_app.py`, `tasks.py`, `worker.py`: swap the queue

Replace `procrastinate_app.py`'s `procrastinate.App` with an `rqueue.Queue`
bound to an asyncpg pool, per the Quickstart in rqueue's README. Pick a
schema name that doesn't collide with `compute` (picv-2025's own schema) --
`task_queue` (rqueue's default) or another name of your choice.

Rewrite `tasks.py`:

- `enqueue_simulation` becomes `async def enqueue_simulation(connection,
  compute_job_id)`, calling `queue.enqueue(connection, task=...,
  payload={"compute_job_id": str(compute_job_id)}, dedupe_key=...,
  on_conflict="return_existing", ...)`.
- `run_simulation_task` becomes an `async def` handler registered via
  `@queue.task(name=..., retry=..., timeout=...)`, taking `(payload,
  context: TaskContext)`. Inside:
  - Fetch the job row and call the now-async `repository` functions with
    `await`.
  - The CPU-bound `run_simulation(...)` call runs off the event loop:
    `await asyncio.to_thread(run_simulation, ...)`. `rqueue.Worker` installs
    a bounded default executor for exactly this; verify by reading
    `worker.py` and the executor test file (find its real name; the prior
    report says `tests/test_executor_bound.py`, confirm it still exists).
  - **The `on_progress` callback bridge:** the prior report's design
    (`asyncio.run_coroutine_threadsafe(repository.record_progress(...),
    loop).result()`, capturing the loop before entering the thread, one
    pooled connection borrowed per write rather than one held for the whole
    task) is sound and tested (it verified the thread genuinely lands in
    rqueue's bounded executor, not the interpreter's default one) -- reuse
    it.
  - Retries: `TRANSIENT_RETRY`/`RetryStrategy(retry_exceptions=
    (TransientInfraError,))` maps to `RetryPolicy(max_attempts=n,
    retry_on=(TransientInfraError,))` -- `RetryPolicy.retry_on` is a genuine
    exception allowlist (confirmed against `retry.py`/`errors.py` in the
    prior run). `bump` has a real `TransientInfraError`
    (`api/core/errors.py`), so this mapping applies directly, unlike the
    prior attempt where no such class existed.
  - Delete `reap_stalled_jobs_task`, `reap_action`, `ReapAction`,
    `STALLED_HEARTBEAT_SECONDS`, `CRASH_REQUEUE_DELAY_SECONDS`,
    `CRASH_BUDGET_EXHAUSTED_ERROR`, `_fail_exhausted` -- superseded by
    rqueue's built-in lease recovery.
  - Port `sweep_abandoned_work_dirs_task` per the note above.

Rewrite `worker.py`'s `main()` to run an asyncio event loop that creates the
pool, builds the `Queue`, constructs an `rqueue.Worker`, and calls `await
worker.run()`, closing the pool on exit, with a `SIGTERM` handler calling
`worker.stop()` (the prior report added `loop.add_signal_handler(SIGTERM,
worker.stop)` and verified clean shutdown by hand -- reuse it). Keep the
existing `numba.set_num_threads(...)` setup logic.

### 5. Do not touch (out of scope for this task)

- `queue_migrate.py`, `migrate.py`, `web_grants.py` -- one-shot deploy-time
  CLI scripts, not on any request/worker hot path. `queue_migrate.py`
  specifically installs Procrastinate's schema and will need to be replaced
  by rqueue's own migration CLI, but that's stage 2's job. If leaving it
  untouched would break `docker-compose.yml`'s bootstrap (it likely does --
  check what actually invokes it), fix the minimum needed to keep the stack
  bootable (as the prior run did, swapping in `rqueue ... migrate` in
  `docker-compose.yml`) without addressing what happens to an
  already-deployed Procrastinate schema -- that's still stage 2's problem,
  say so plainly.
- `relq` -- not used here at all. Don't add it as a dependency.
- `compute.jobs`'s own schema/DDL -- unchanged; only how it's read/written
  changes.

## Dependencies

Add `asyncpg` to `packages/api/pyproject.toml` via `uv add`. Remove
`procrastinate`. Check whether `psycopg[binary,pool]` can be fully removed
or must stay because other files (`migrate.py`/`web_grants.py`/
`queue_migrate.py`) still import it directly -- don't remove a dependency
files you didn't touch still use.

`rqueue` is not on PyPI yet. Add it as a `uv add` path dependency pointing
at `~/git/transactions` (the prior run used `uv add --package tsdhn-api
~/git/transactions`, which worked and produced a `[tool.uv.sources]` entry
-- reuse that invocation). State clearly that this is a local,
machine-specific dependency that needs a real version pin once rqueue is
released.

Check whether `packages/api/pyproject.toml`'s `requires-python` is
compatible with rqueue's `>=3.13` (it very likely is; confirm rather than
assume).

If `pip-audit --strict` (or equivalent) breaks on the new path dependency,
the prior report's fix (`--no-emit-package rqueue` on the export step, with
a comment to remove it once rqueue is published) is a known-good pattern.

## Tests

Existing tests that stub or assert against `psycopg`/Procrastinate behavior
will need real rewriting to asyncpg/rqueue fixtures -- expect this. Breaking
changes here are expected and pre-approved. If real PostgreSQL-backed
integration test infrastructure doesn't already exist on `bump`, you may
need to build it (mise Postgres task, a disposable-database conftest
fixture, a CI service container) -- the prior report's approach (project-local
Postgres via `mise`, disposable per-test database/schema, `pytest -m
integration`, a CI service container) is a reasonable template if `bump`
doesn't already have something equivalent; check first.

## Verification

Run the full `packages/api` test suite against a real PostgreSQL instance.
Also do at least one direct, non-test check: start the worker and API
process by hand against a real database, submit a job through `POST
/api/v1/jobs`, and confirm it runs to completion and the SSE endpoint
reports it via real push notifications (not just polling) -- state plainly
if you could not do this and why.

## Deliverable

Leave changes uncommitted. Write a report to
`~/git/captain/notes/transactions/picv-asyncpg-rqueue-v2.md` (new file, do
not overwrite the prior report) covering: every design decision, what you
deleted and why, the rqueue dependency you used, and your verification
results. Where you followed the prior report's design as-is, say so briefly
rather than re-deriving the reasoning; where `bump`'s real code forced a
different choice, explain why. If something in this brief turns out to be
wrong once you're looking at the real code, say so plainly with the
concrete evidence.
