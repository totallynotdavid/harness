# picv-2025: psycopg/Procrastinate -> asyncpg/rqueue (stage 1)

Branch `cap/picv-asyncpg-rqueue`, changes left uncommitted.

---

## Read this first: the brief describes a codebase that isn't there

The task brief's "Current shape" section does not match `packages/api` as it
exists on `master` (`57446fc`). This is not a small drift -- most of the named
files, functions and behaviours are absent. I did the driver/queue swap on the
code that is actually there, and mapped each instruction onto its real
counterpart. Concretely:

| Brief says | Reality on `master` |
| --- | --- |
| `api/core/db.py` with a `psycopg_pool.ConnectionPool`, `pooled()`, `connect()` | **No such file, and no pool at all.** Every operation opened its own `psycopg.connect(COMPUTE_DATABASE_URL, connect_timeout=2)`. |
| `api/core/repository.py` with `mark_started`, `record_progress`, `record_failure`, `fail_job`, `complete_job`, `_notify` | **No such file.** The equivalent is a `ComputeJobs` class plus two module helpers (`_progress_update`, `_complete_job`) inside `api/core/jobs.py`. |
| `create_or_get_job(*, data, simulation_id, defer)` -- the `defer` seam already exists | **No `defer` parameter.** `create_or_get_job(*, data, external_id)` called `run_simulation_task.configure(...).defer(...)` inline, so `jobs.py` imported Procrastinate directly. I added the `defer` seam as part of this work; it was not already there. |
| Table `compute.jobs` in a `compute` schema; DDL in `api/core/schema.py` | Table is `compute_jobs` in the default search path (`public`). Its DDL is the `COMPUTE_JOBS_SCHEMA` constant inside `jobs.py`, applied by `install_compute_schema()`. There is no `api/core/schema.py`. |
| `api/core/tasks.py` | **No such file.** The single task lived in `jobs.py`. |
| `job_events` (SSE) opens a `psycopg.AsyncConnection` and uses `LISTEN` / `aconn.notifies(...)`, with keepalive and deadline logic | **There is no `LISTEN` and no `NOTIFY` anywhere in the repository.** `job_events` is a plain loop that re-reads job status every 2 seconds via `anyio.to_thread.run_sync`, with no keepalive and no deadline. |
| `_notify(conn, ...)` paired with `conn.commit()`, hence the instruction to wrap those bodies in `async with conn.transaction()` | No `_notify` exists, and every function that ended in `conn.commit()` ran **exactly one** statement. See "Transactions" below for what this means. |
| `reap_stalled_jobs_task`, `reap_action`, `ReapAction`, `STALLED_HEARTBEAT_SECONDS`, `CRASH_REQUEUE_DELAY_SECONDS`, `CRASH_BUDGET_EXHAUSTED_ERROR`, `_fail_exhausted` | **None of these exist.** There is no reaper to delete. |
| `sweep_abandoned_work_dirs_task` (hourly `@app.periodic`) | **Does not exist.** There are no periodic tasks at all. |
| `TRANSIENT_RETRY`, `RetryStrategy`, `retry_exceptions=(TransientInfraError,)` | **None of these exist.** The task was registered `retry=False`. There is no `TransientInfraError` class in the repository. |
| `queue_migrate.py`, `web_grants.py` | **Neither file exists.** Only `api/migrate.py`, which is 9 lines calling `install_compute_schema()`. |
| `psycopg[binary,pool]` in `packages/api/pyproject.toml` | It was `psycopg[binary]` -- no `pool` extra, consistent with there being no pool. |
| Worker entrypoint has `numba.set_num_threads(...)` setup to preserve | `numba` appears nowhere in the repository. `worker.py` was 20 lines: `app.open()`, `app.run_worker(...)`, `app.close()`. |
| Tests `test_db.py`, `test_jobs.py`, `test_repository_integration.py`, `test_tasks.py`, `conftest.py`; "these tests already use [a real PostgreSQL database]; keep that" | The only test file was `packages/api/tests/test_api.py`, and it uses **no database at all** -- it monkeypatches `routes.compute_jobs` with hand-written stubs. There was no `conftest.py`, no PostgreSQL in `mise.toml`, and no PostgreSQL service in CI. |

One smaller mismatch on the rqueue side: the brief says to verify the bounded
executor "by reading `worker.py` and `tests/test_worker_concurrency.py`". That
test file does not exist; the equivalent is `tests/test_executor_bound.py`. The
claim itself checks out -- `Worker._runtime()` enters
`bounded_default_executor(self.executor_max_workers, ...)`, and
`Worker._tick()` calls `Storage.recover_expired_leases(...)` on every poll,
exactly as described.

Everything the brief says about `rqueue` itself was accurate.

---

## What I built

New modules, chosen to mirror the brief's intended structure onto the real code:

- `packages/api/api/core/db.py` -- the process-wide asyncpg pool.
- `packages/api/api/core/queue.py` -- the `rqueue.Queue` (replaces the deleted `procrastinate_app.py`).
- `packages/api/api/core/tasks.py` -- `enqueue_simulation`, `run_simulation_task`, `register_tasks`, `build_queue`. The only module that imports `rqueue` on the application side.
- `packages/api/api/core/jobs.py` -- rewritten as the async repository. Imports no queue.

Changed: `settings.py`, `routes.py`, `main.py`, `worker.py`, `pyproject.toml`,
`docker-compose.yml`, `scripts/e2e/backend_stack_smoke.sh`, both readmes, CI,
`mise.toml`, `.gitignore`.

Deleted: `packages/api/api/core/procrastinate_app.py`.

---

## The decisions the brief left to judgement

### Pool shape: one helper, one pool per process, no long-lived worker connection

`db.py` exposes `open_pool(min_size, max_size)`, `close_pool()`, `get_pool()`
and an `acquire()` context manager. Both processes use it: the API opens a pool
in its FastAPI lifespan, the worker opens one in `main()`. They differ only in
size, via `api_pool_size()` / `worker_pool_size()` in `settings.py`.

I did **not** keep a dedicated long-lived connection for the worker task, and
this is a deliberate departure from the shape the brief sketched. Every
repository call borrows a pooled connection for the length of one statement (or
one transaction) and gives it straight back. Reasons:

1. A simulation is minutes to tens of minutes long and touches the database
   only in the progress callback. Pinning a connection for the whole run buys
   nothing and exposes it to idle-connection reapers on the server side.
2. It removes the thread-safety question entirely. There is no connection
   object whose ownership could be confused between the simulation thread and
   the loop.
3. `rqueue.Worker` already works this way -- it never holds a transaction open
   across user code.

The one place a connection lives across statements is `create_or_get_job`,
which is the point: `async with db.acquire() as connection,
connection.transaction():` wraps the `compute_jobs` insert and the `defer(...)`
enqueue, so they commit together or not at all.

**Worker pool sizing is load-bearing, not cosmetic.** `worker_pool_size()`
floors the pool at `2 * concurrency + 4`. `rqueue.Worker._listener()` acquires
one connection and holds it for the entire run to `LISTEN` on the wake channel;
`_tick()` borrows another each poll; each in-flight job's progress callback
borrows one per `UPDATE`. Undersize this and the listener silently fails to
establish (rqueue logs a warning and falls back to polling), which is a latency
regression that would be easy to misdiagnose. This is written down in the
docstring.

### Progress callback: `run_coroutine_threadsafe`, own pooled connection per write

`run_simulation_task` captures `asyncio.get_running_loop()` before entering
`asyncio.to_thread`, and `on_progress` does:

```python
asyncio.run_coroutine_threadsafe(
    compute_jobs.record_progress(compute_job_id, details=message, values=details),
    loop,
).result()
```

`.result()` blocks the simulation thread until the write lands, matching what
the synchronous Procrastinate task did -- progress is written before the
simulation moves on, and a failure to write surfaces in the simulation thread
rather than being swallowed.

The write uses a connection acquired from the pool for that statement alone
(consequence of the pool decision above). No asyncpg connection object ever
crosses a thread boundary; the coroutine that touches it runs on the loop
thread.

Verified in `test_worker_integration.py`: the stubbed kernel records
`threading.current_thread().name`, and the test asserts it starts with
`rqueue-` (rqueue's bounded executor thread-name prefix) and is not the main
thread -- so the `to_thread` hop really does land in rqueue's capacity-bounded
executor, not the interpreter's default one.

### Periodic tasks: none, because there are none

`sweep_abandoned_work_dirs_task` does not exist in this codebase (see the table
above), so there was nothing to port and no mechanism to choose. I did not
introduce `rqueue.Scheduler`; adding a scheduler process with no schedules to
run would be dead weight.

For the record, had there been one: for a single, simple, non-job-producing
housekeeping sweep I would use a plain `asyncio` task in the worker process
rather than `Scheduler`. `Scheduler`'s occurrence-key machinery earns its
complexity when several replicas must not double-fire a *job*; a `rmtree` of
already-failed work directories is idempotent and harmless to run twice.

### Retry mapping: `RetryPolicy(max_attempts=1)`

The brief asks to map `retry_exceptions=(TransientInfraError,)` onto rqueue.
Neither `TRANSIENT_RETRY` nor `TransientInfraError` exists here; the
Procrastinate task was registered `retry=False`, i.e. one attempt and a durable
failure. The faithful translation is `RetryPolicy(max_attempts=1)`, which is
what `NO_RETRY` in `tasks.py` is.

To answer the question the brief actually asked -- rqueue expresses "retry this,
not that" **both** ways, and I read `retry.py` / `errors.py` rather than
guessing:

- `RetryPolicy.retry_on: Sequence[type[BaseException]]` is a genuine exception
  allowlist (default `(Exception,)`), and `retry_if` is an escape hatch
  predicate. So `retry_exceptions=(TransientInfraError,)` would port directly
  as `RetryPolicy(max_attempts=n, retry_on=(TransientInfraError,))`.
- `PermanentFailure` is *additionally* never retried regardless of `retry_on`
  (`RetryPolicy.should_retry` checks it first). It is the handler saying "this
  job cannot succeed", not a policy setting.

With `max_attempts=1` neither is consulted for the simulation task. `tasks.py`
carries a comment saying where a future `TransientInfraError` allowlist would
go. `run_simulation_task` does use `PermanentFailure` for "no such compute
job", which is correct independent of the policy.

### Dedupe key, and why no concurrency key

`enqueue_simulation` uses `dedupe_key=f"simulation:{compute_job_id}"` with
`on_conflict="return_existing"`, which is rqueue's own documented example and
the 1:1 replacement for Procrastinate's
`queueing_lock=f"simulation:{app_job_id}"`.

Worth being honest about what actually enforces idempotency here: the
`compute_jobs.external_id` UNIQUE constraint plus `ON CONFLICT DO NOTHING`
does. A second POST with the same `app_job_id` never reaches `defer` at all --
it takes the "return the existing row" branch. The dedupe key is a second guard
at the queue layer, not the primary one. Verified end to end: a duplicate POST
returned the same `compute_job_id` and left exactly one row in
`task_queue.jobs`.

I did **not** add `concurrency_key`. Procrastinate's `lock` was never set in
this codebase, one compute job maps to exactly one queue job, and a
concurrency key does not prevent the one overlap that matters (a stalled
worker's thread still running while its lease is recovered) -- rqueue's fencing
token does that. Adding an unused primitive would be noise.

### Queue schema

`task_queue` (rqueue's default), configurable via `COMPUTE_QUEUE_SCHEMA`.
`compute_jobs` stays where it is. Confirmed on a live database: after
`rqueue ... migrate`, `public` holds only `compute_jobs`, and the nine rqueue
tables are all under `task_queue`.

---

## What I deleted, and what I left alone

**Deleted:** `api/core/procrastinate_app.py` (the `procrastinate.App`), and the
`PROCRASTINATE_QUEUE` setting (now `COMPUTE_QUEUE`).

The reaper, the sweeper, the retry constants and the whole `tasks.py` the brief
asked me to prune **did not exist**, so there was nothing to delete. rqueue's
built-in lease recovery (`Worker._tick` -> `Storage.recover_expired_leases`)
is a net *gain* here rather than a replacement: Procrastinate's stalled-job
handling was never wired up in this repository in the first place.

**Left alone:** `api/migrate.py`, exactly as instructed -- it is untouched, not
even its import line. To keep it that way, `install_compute_schema()` kept its
synchronous signature and now wraps an `asyncio.run(...)` over a one-shot
`asyncpg.connect(...)`. `queue_migrate.py` and `web_grants.py` were not left
alone so much as never existed.

**Dead code note, as requested:** nothing in `packages/api` is left dead by this
change. The Procrastinate schema installation lived in `docker-compose.yml`, not
in a Python file -- see the next section.

---

## Things I had to touch that the brief did not anticipate

### `psycopg` is gone entirely

The brief's rule is "don't remove a dependency three untouched files still use".
Those three files don't exist. The *only* importer of `psycopg` in the whole
repository was `api/core/jobs.py`, which this task rewrites. So `psycopg` is
removed as a direct dependency and there is now exactly one PostgreSQL driver
in the process, which is REQUIREMENTS.md §1's actual motivation for rqueue
existing. `install_compute_schema()` was converted to asyncpg along with the
rest of the module.

### `docker-compose.yml`: the Procrastinate migration would have broken the stack

`compute-migrate` ran
`procrastinate --app=api.core.procrastinate_app.app schema --apply`, and both
`api` and `worker` gate on `service_completed_successfully` for it. Removing
the `procrastinate` dependency turns that into "command not found" and takes
the entire stack down -- it is not merely dead code. I replaced it with
`rqueue --database-url "$$COMPUTE_DATABASE_URL" --schema task_queue migrate`.

This edges into what the brief called stage 2's job. I did the minimum to keep
the stack bootable and nothing more: **it does not address what happens to
already-deployed Procrastinate schemas or their in-flight jobs**, which is
still stage 2's problem. Note `--schema` is a *global* flag on the `rqueue` CLI,
before the subcommand, not a `migrate` flag; I verified the exact invocation
against a real database.

### `pip-audit --strict` breaks on a path dependency

`uv export --no-emit-workspace` drops workspace members but keeps `rqueue`,
because a path dependency is not a workspace member. The exported requirements
then contain a bare `../../git/transactions` line and the audit fails:

```
ERROR:pip_audit._cli:rqueue: Dependency not found on PyPI and could not be audited: rqueue (0.2.0)
```

I added `--no-emit-package rqueue` to the export in both `mise.toml`'s
`security` task and `.github/workflows/security.yml`, with a comment saying to
remove it once rqueue is published. rqueue is audited in its own repository.
After the change the audit runs clean apart from one pre-existing finding
(`pip 26.1.2`, PYSEC-2026-3721) that comes in via the `pip-audit` dev
dependency itself and is present on `master` too.

### `scripts/e2e/backend_stack_smoke.sh`

`assert_queued_job` asserted against `procrastinate_jobs` in `public`. Now
asserts `task_queue.jobs` with `task = 'api.run_simulation' AND queue =
'simulations'`. Not run here (it needs the full compose stack).

### Test infrastructure had to be built, not rewritten

The brief says the existing tests use a real PostgreSQL and to keep that. They
do not, and there was no way to get one. I added:

- `mise.toml`: `postgres = "18.6"` and `pg:init` / `pg:start` / `pg:stop` /
  `pg:reset`, mirroring rqueue's own tasks, on **port 5433** so a project-local
  cluster does not collide with the compose stack's published 5432 (or, in
  practice, with rqueue's own cluster on the same machine). Cluster lives in
  `.data/postgres`, now gitignored.
- `scripts/integration.sh`: creates `tsdhn_integration_<ts>_<pid>`, applies both
  schemas, runs `pytest -m integration`, drops it in a `trap ... EXIT`. Honours
  a pre-set `COMPUTE_TEST_DATABASE_URL` and skips the create/drop, which is how
  CI supplies its service container. Same shape as rqueue's.
- `mise run test` is now `-m 'not integration'`; `mise run test-integration`
  is the database task.
- `.github/workflows/ci.yml`: a `postgres:18-alpine` service on the test job,
  `COMPUTE_TEST_DATABASE_URL` in the job env, the main run marked
  `-m "not integration"`, and a second serial step running the integration
  suite. Without this the new tests would silently skip in CI.

---

## Dependencies

Added with `uv add` (not hand-edited):

- `asyncpg>=0.31.0`. Installs and imports cleanly on this workspace's Python
  3.14.7, contrary to the caution in rqueue's REQUIREMENTS §2 -- there are 3.14
  wheels for 0.31.0.
- `rqueue` as a **path dependency**: `uv add --package tsdhn-api
  ~/git/transactions`, which wrote
  `[tool.uv.sources] rqueue = { path = "../../../../git/transactions" }` into
  `packages/api/pyproject.toml`.

**This is a local, machine-specific dependency.** It resolves only on a machine
that has `~/git/transactions` checked out, and it will need to become a real
version pin once rqueue is published. It happens to resolve correctly from both
the main checkout and this worktree only because both sit four directories below
`$HOME`; that is luck, not design. Not solving it here, per the brief.

Removed: `procrastinate>=3.9.0`, `psycopg[binary]>=3.3.4`.

`requires-python`: `packages/api` stays `>=3.14`, which satisfies rqueue's
`>=3.13`. No floor change.

---

## Two brief instructions I did not carry out, and why

### 1. The SSE `LISTEN`/`NOTIFY` rewrite

The brief asks to replace `job_events`' `psycopg.AsyncConnection` /
`LISTEN` / `aconn.notifies(...)` block with asyncpg's `add_listener` bridged
through an `asyncio.Queue`, "keeping the existing behavior" of keepalives and
deadlines.

**There is nothing to replace.** `git grep -i 'listen\|notify\|pg_notify'` over
`packages/` returns nothing. The endpoint is a 2-second polling loop and always
has been; there is no `NOTIFY` on any write path to listen for. Building the
listener would mean *adding* `pg_notify` to five write paths and a new SSE
architecture -- a feature, not a driver swap, and outside "a pure driver/queue
swap".

What I did instead: `job_events` now awaits `compute_jobs.get_job_status(...)`
directly instead of pushing it to a thread. Same 2-second cadence, same
terminal-state exit, same error event. This is a good follow-up task and I'd
recommend filing it -- the polling loop is real latency (up to 2s per state
change) and rqueue already proves the asyncpg listener pattern works.

### 2. Transaction-wrapping the multi-statement writers

The brief says to check `mark_started`, `record_progress`, `record_failure`,
`fail_job` and `complete_job` for the "UPDATE then `_notify` then `commit()`"
pattern and wrap each in `async with conn.transaction()`.

The reasoning is right but the premise isn't: with no `_notify`, every one of
those functions ran a **single** statement before `conn.commit()`. Under
asyncpg's implicit autocommit a single statement is already atomic, so wrapping
it in an explicit transaction would add a round trip for nothing. I did not.

The one function that genuinely needs a transaction is `create_or_get_job`
(insert + enqueue), and it has one. `test_a_rolled_back_producer_leaves_neither_row`
proves it: a `defer` that raises after enqueueing leaves zero rows in *both*
`compute_jobs` and `task_queue.jobs`.

If `NOTIFY` is added later (see above), those wrappers become necessary and the
brief's instruction becomes correct.

---

## Verification

### Static

```
$ mise x -- uv run ruff check . --select E,F,W,I,B,UP,S,SIM,RUF
All checks passed!
$ mise x -- uv run ruff format --check .
44 files already formatted
$ mise x -- uv run mypy --strict packages
Success: no issues found in 44 source files
```

One lint concession: `S608` added to the `**/tests/**` per-file-ignores, because
the integration tests interpolate the per-test queue schema name into SQL and
PostgreSQL has no bind parameter for an identifier. Same concession rqueue makes
in its own `pyproject.toml`, for the same reason. Production code has no
interpolated SQL at all -- the `compute_jobs` column lists are spelled out
literally rather than built with an f-string, precisely so no `# noqa` is needed
in `jobs.py`.

### Tests

```
$ mise x -- uv run pytest packages/api/tests -q -m "not integration"
11 passed, 14 deselected

$ bash scripts/integration.sh -q
14 passed, 59 deselected
```

New test files:

- `tests/test_enqueue.py` (4 tests, no database) -- `rqueue.testing.RecordingQueue`
  runs the real `Queue.build_insert` validation and records instead of writing,
  proving `enqueue_simulation` builds a well-formed job: right task name (a typo
  fails), right payload, right dedupe key, `max_attempts` inherited from
  `NO_RETRY`, and the caller's connection passed straight through. Also covers
  "unregistered task name is a failure" and "queue unavailable before
  `build_queue`".
- `tests/test_jobs_integration.py` (10 tests, real PostgreSQL) -- transactional
  enqueue commits both rows; a rolled-back producer leaves neither; the same
  external id returns the existing job and enqueues once; conflicting input is
  rejected; the `$n::text::jsonb` / `::text` round trip preserves nested JSON
  and `COALESCE` leaves unmentioned columns alone; `mark_started` returns the
  row it updated and `None` for an unknown job; failure records the error.
- `tests/test_worker_integration.py` (4 tests, real PostgreSQL and a real
  `rqueue.Worker`) -- a queued simulation runs to completion through
  `Worker.drain()` with progress, artifacts and terminal state all correct, and
  the kernel demonstrably on an `rqueue-` executor thread; a failing kernel
  fails the job with exactly one attempt; an unknown compute job becomes a
  `PermanentFailure`; an undecodable payload fails before the handler is ever
  called.
- `tests/conftest.py` -- disposable per-test queue schema, both schemas applied,
  pool opened against `COMPUTE_TEST_DATABASE_URL`, skipping when it is unset.

`tests/test_api.py` needed only its stubs made `async def` and a lifespan that
does not open a pool; it also now asserts the route passes `enqueue_simulation`
as `defer`.

### By-hand run against a real database

Ran `tsdhn-worker` and `tsdhn-api` as separate processes against the
project-local PostgreSQL 18.6 (port 5433) and a MinIO container, with the real
Fortran/TTT toolchain extracted from the existing `localhost/tsdhn-api:local`
image (the machine has neither `ifort` nor `gfortran`, and `ttt_client` /
`libttt.so.4` are not installable from source here).

Confirmed:

- `GET /api/v1/health` -> `{"status": "healthy", "database_connected": true,
  "storage_connected": true}` -- the asyncpg pool and the threaded MinIO probe.
- `POST /api/v1/jobs` -> `201` with `status: "queued"`, and one row in
  `task_queue.jobs` with `task = api.run_simulation`, `queue = simulations`,
  `max_attempts = 1`, `dedupe_key = simulation:<compute_job_id>`.
- A duplicate `POST` returned the same `compute_job_id` and did not create a
  second queue row.
- The worker claimed the job within a second (`state = leased, attempt = 1`).
- `GET /api/v1/jobs/{id}/events` streamed live status through the run.

- A duplicate `POST` returned the same `compute_job_id`; a `POST` with the same
  `app_job_id` and different input returned `400`. Exactly one row in
  `compute_jobs` and one in `task_queue.jobs` throughout.
- Lease heartbeating works under a long blocking handler. Sampled mid-run
  repeatedly: `state = leased`, `now() - heartbeat_at` between 7 and 20 seconds
  against a 60-second lease. The `asyncio.to_thread` hop leaves the event loop
  free, so rqueue's heartbeat task keeps the lease alive for the whole run
  without the handler doing anything.

**The job ran to completion.** All 8 pipeline steps, 17m02s wall clock, the
real Fortran kernel (33602 timesteps) and the real GMT rendering:

```
SSE state progression (509 events):
  running  tsunami       3/8  Processing tsunami
  running  maxola        4/8  Processing maxola
  running  ttt_inverso   6/8  Processing ttt_inverso
  running  point_ttt     7/8  Processing point_ttt
  completed copy_ttt_pdf 8/8  Simulation completed successfully

task_queue.jobs:  state = succeeded, attempt = 1, error_type = NULL, duration = 00:17:02
compute_jobs:     status = completed, step_index = 8, total_steps = 8,
                  result_bucket = tsdhn-results,
                  result_key = simulations/<app_job_id>/metadata.json
GET /api/v1/jobs/<app_job_id>: artifacts_available = true
```

MinIO holds all nine expected objects (`metadata.json` plus
`calculation.json`, `input.json`, `travel_times.json`, `travel_times.csv`,
`runtime.json`, `mareograma.svg`, `maxola.pdf`, `ttt.pdf`), and the per-job
work directory under `TSDHN_JOBS_DIR` was removed afterwards -- so the
`asyncio.to_thread` MinIO upload, the `complete_job` write and the threaded
`rmtree` all did their jobs.

**One environment workaround was needed, unrelated to this change.** The first
attempt failed at step 4 (`maxola`) with:

```
GMTCLibError: Module 'psconvert' failed with status code 79:
psconvert [ERROR]: System call [gs -q -dNOSAFER ... '/home/dubu/.gmt/sessions/gmt_session.N/gmt_1.ps-' ...] returned error 256.
Error: /undefinedfilename in (.../gmt_1.ps-)
```

This host's Ghostscript 10.06.0 refuses to open a filename ending in `-`, and
GMT 6.6 names its temporary PostScript file `gmt_1.ps-`. Reproduced in two
lines with no picv code involved at all -- a bare
`pygmt.Figure().basemap(...).savefig(...)` fails identically, and `gs` on the
same file succeeds the moment the trailing dash is removed. It is a host
GMT/Ghostscript version pairing, which the compose toolchain image does not
have. For the run above I put a three-line `gs` wrapper on `PATH` that copies
such an argument to a dash-free temporary name. **That wrapper is a local
verification aid in the scratch directory; nothing about it is in the
repository, and nothing in this change depends on it.**

Two further caveats on how this run was staged, for honesty about what it does
and does not prove: the machine has neither `ifort` nor `gfortran` and cannot
build the model executables, and `ttt_client`/`libttt.so.4` come from a private
GitLab SDK, so I extracted `fault_plane`, `deform`, `tsunami`, `ttt_client` and
the Intel/TTT runtime libraries from the existing `localhost/tsdhn-api:local`
image rather than building them. The *simulation binaries* are therefore the
same ones the deployed image uses, but the Python process running them is the
working tree. Separately, `mise x -- ...` overwrites `LD_LIBRARY_PATH` with its
own tool paths, so the processes were started through the `uv` binary directly;
that is a local-invocation detail, not something the deployment does.

Also verified by hand:

- `SIGTERM` to the worker process exits cleanly in about a second via the
  handler added in `worker.py` (`loop.add_signal_handler(SIGTERM,
  worker.stop)`). Note it must reach the worker process itself; signalling an
  intervening `uv run` wrapper does not propagate promptly, which is a local
  invocation artefact -- the container runs `tsdhn-worker` directly.
- `rqueue --schema task_queue migrate` puts all nine queue tables in
  `task_queue`, leaving `public` holding only `compute_jobs`.
- The API's `/health` reports `database_connected: true` off the asyncpg pool
  and `storage_connected: true` off the now-threaded MinIO probe.

---

## Follow-ups worth filing

1. **SSE via `LISTEN`/`NOTIFY`** -- what the brief asked for, but as the feature
   it actually is. Needs `pg_notify` on the write paths first, and then the
   transaction wrappers the brief describes become correct.
2. **The `rqueue` path dependency** must become a version pin when rqueue
   publishes.
3. **Stage 2's migration story** -- `docker-compose.yml` now runs rqueue's
   migrate, but nothing decides what happens to an already-deployed
   `procrastinate_*` schema and its rows.
4. **`packages/api` has no `TransientInfraError`.** If transient-infrastructure
   retries are actually wanted (the brief assumes they exist), that is a
   separate piece of work; `tasks.py` marks where the policy would go.
