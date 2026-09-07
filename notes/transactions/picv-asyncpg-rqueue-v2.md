# picv-2025: psycopg/Procrastinate -> asyncpg/rqueue (stage 1), on `bump`

Branch `cap/picv-asyncpg-rqueue-v2`, off `bump` at `90aef46`. Changes left
uncommitted.

This is the re-run of the task the prior report
(`picv-asyncpg-rqueue.md`) attempted against `master`. Unlike that run, the
brief's "Current shape" section matches the code: every file, function and
behaviour it names exists on `bump`. Where I followed the prior report's
design I say so briefly rather than re-deriving it; where `bump`'s real code
forced a different choice I say why.

Six review passes found real problems in this change. All the real ones are
fixed and re-verified; two findings had premises that did not hold, and one
asked for work whose premise (a live deployment) does not exist. "Review
findings" below records each one, what was done, and the evidence where I
disagreed.

The third pass also **lifted the brief's "`compute.jobs` DDL is out of scope"
restriction**, specifically so the abandoned-attempt race could be fenced
properly rather than bounded. It is now fenced, and the section below that used
to describe a residual describes a fix.

---

## What changed

| File | What happened |
| --- | --- |
| `api/core/db.py` | psycopg pool -> `asyncpg.create_pool`. `open_pool`/`close_pool`/`get_pool`/`acquire()`, plus `connect()` for the SSE listener and `transient_connection_errors()` for statement-level failures. |
| `api/core/repository.py` | Every function `async def`; `%s` -> `$n`; `Jsonb(...)` -> `$n::text::jsonb` / `::text` on read; each notifying writer wrapped in `async with conn.transaction()`; `reconcile_terminal_jobs` added; `fail_job` deleted with the reaper it served. |
| `api/core/queue.py` | **New.** Holds the `rqueue.Queue` (`build_queue`/`get_queue`/`set_queue`). Replaces `procrastinate_app.py`. |
| `api/core/tasks.py` | Rewritten on rqueue: `enqueue_simulation`, the async `run_simulation_task`, `register_tasks`, `sweep_abandoned_work_dirs`, `reconcile_terminal_jobs`, and the two periodic loops over `_run_periodically`. |
| `api/routes.py` | No more `anyio.to_thread.run_sync` around the repository; SSE rebuilt on `Connection.add_listener` bridged through an `asyncio.Queue`. |
| `api/main.py` | Lifespan opens the pool, builds and registers the queue. |
| `api/worker.py` | `asyncio.run` -> pool -> `Queue` -> `rqueue.Worker.run()`, SIGTERM/SIGINT -> `worker.stop()`, plus the two maintenance tasks (sweep, reconcile). numba setup kept. |
| `api/core/settings.py` | `PROCRASTINATE_*` -> `COMPUTE_QUEUE` / `COMPUTE_QUEUE_SCHEMA`; `api_pool_size()` / `worker_pool_size()`; worker concurrency, lease, id. |
| `api/core/procrastinate_app.py` | **Deleted.** |
| `api/queue_migrate.py` | **Deleted** — see "The one place the brief contradicts itself". |
| `docker-compose.yml`, `.env.example`, `mise.toml`, `scripts/integration.sh`, `scripts/e2e/*.sh`, readmes, `ARCHITECTURE.md` | Procrastinate's schema install -> `rqueue ... migrate`; queue assertions -> `task_queue.jobs`; `COMPUTE_QUEUE`/`COMPUTE_QUEUE_SCHEMA` reach every service that reads them. |
| `api/core/schema.py` | One column added: `owner_attempt`, the attempt fence. The brief excluded `compute.jobs`' DDL; the third review round lifted that specifically for this. |
| Tests | `conftest.py`, `test_db.py`, `test_jobs.py`, `test_tasks.py`, `test_api.py`, `test_repository_integration.py` rewritten; `test_worker_integration.py` added (16 tests); two Procrastinate tests in `test_migrations_integration.py` replaced by one. |

`api/migrate.py`, `api/web_grants.py`, `api/schemas.py`, `api/security.py`,
`api/core/storage.py` and `api/core/errors.py` are untouched (one stale word in
`migrate.py`'s docstring — "the Procrastinate and web schemas" -> "the queue and
web schemas" — is the only edit to that file). `compute.jobs`' existing columns
are untouched; the one addition is `owner_attempt`, under the exception noted
above. `GRANT SELECT ON compute.jobs` is table-level, so the web role needs no
new grant for it.

---

## Design decisions

### Pool shape — the prior report's design, reused as-is

One `db.open_pool`/`close_pool`/`get_pool`/`acquire()` helper shared by both
processes, sized differently through `settings.api_pool_size()` /
`worker_pool_size()`. No dedicated long-lived connection for the worker task:
every repository call borrows a pooled connection for one statement or one
transaction and gives it straight back. The reasoning is the prior report's
(a simulation is minutes long and touches the database only in the progress
callback; no connection object crosses a thread boundary; rqueue's own worker
works the same way) and I did not re-derive it.

`worker_pool_size()` floors the pool at `2 * concurrency + 4` for the reason
that report gives, restated in its docstring: `rqueue.Worker._listener()`
holds one connection for the entire run to `LISTEN`, and an undersized pool
makes that fail silently into polling-only. `test_db.py` asserts the floor
exceeds concurrency rather than just asserting the arithmetic.

**One departure from the prior design.** `DB_POOL_MIN_SIZE` now defaults to
`0`, not `1`. `bump`'s psycopg pool opened with `open(wait=False)`, so the API
process started before PostgreSQL was reachable and reported the outage
through `/health`. `asyncpg.create_pool` connects `min_size` connections
eagerly, so a floor of 1 would have turned a slow database into a failed
process start. Verified: with `min_size=0` `create_pool` returns against a
dead server and only `acquire()` raises.

`acquire()` and `connect()` translate `asyncpg.PostgresConnectionError`,
`ConnectionError`, `OSError` and `TimeoutError` into `TransientInfraError`,
preserving the seam the old `db.connect()` had — which is what makes
`RetryPolicy(retry_on=(TransientInfraError,))` mean anything.

### JSON columns

`$n::text::jsonb` on write, `::text` in the `SELECT` list on read, `json.dumps`
/ `json.loads` at the boundary, exactly as the brief specifies and as
`rqueue/storage.py` does. `repository._decode()` is the single place a row
turns into a plain mapping with its JSON parsed, so `status_from_row` and its
existing database-free tests are unchanged.

### Transactions around NOTIFY — needed here, for real

Unlike the prior mis-based run, `bump` genuinely has `_notify` paired with
`conn.commit()` in `mark_started`, `record_progress`, `record_failure`,
`fail_job` and `complete_job`. All five now wrap their statements in
`async with conn.transaction()`, so the existing invariant holds under
asyncpg's per-statement autocommit: a client is never woken to read a state
that has not committed. `test_repository_integration.py` proves it with a real
listener — `mark_started` wakes it, and the row it then reads is `running`.

### The progress callback bridge — the prior report's design, reused

`asyncio.run_coroutine_threadsafe(...).result()`, with the loop captured
before the `asyncio.to_thread` hop, one pooled connection borrowed per write.
`.result()` blocks the simulation thread, keeping the old synchronous
contract: progress is durable before the run moves on, and a write failure
surfaces in the simulation rather than in a dropped task.

Two integration tests cover the thread boundary: `test_tasks.py` asserts the
kernel does not run on the loop thread, and `test_worker_integration.py`
asserts (under a real `rqueue.Worker`) that the thread name starts with
`rqueue-test-worker`, i.e. that the bare `asyncio.to_thread` really lands in
rqueue's bounded default executor and not the interpreter's. `Worker._runtime`
enters `bounded_default_executor(...)` and `Worker._tick` calls
`Storage.recover_expired_leases(...)` on every poll, as the brief says;
`tests/test_executor_bound.py` does still exist in rqueue.

### Retry mapping — a real translation this time

`bump` has `TransientInfraError` and a real `RetryStrategy`, so the mapping the
brief describes applies directly:

```
RetryStrategy(max_attempts=3, exponential_wait=15,
              retry_exceptions=(TransientInfraError,))
-> RetryPolicy(max_attempts=3, initial_backoff=15.0, multiplier=2.0,
               retry_on=(TransientInfraError,))
```

`retry_on` is a genuine allowlist (`RetryPolicy.should_retry` in `retry.py`),
confirmed again here. Two deliberate details:

- **`will_retry` is computed with `TRANSIENT_RETRY.should_retry(exc,
  attempt=context.attempt)`** — the very predicate `Worker._on_exception`
  consults — rather than re-implementing `isinstance(...) and attempts <
  MAX_ATTEMPTS`. The `details` a watching client sees ("retrying" vs terminal)
  therefore cannot drift from what the queue actually does. Note the attempt
  counters differ in base: Procrastinate's `job.attempts` counts *previous*
  attempts, rqueue's `context.attempt` is the 1-based current one. Deferring
  to `should_retry` removes that off-by-one from the application entirely.
- **rqueue's default `jitter=0.1` is kept.** Procrastinate's
  `exponential_wait` has no jitter; this is a small behavioural improvement
  (a fleet failing together no longer retries in lockstep) and not a
  regression, so I did not set it to zero to match.

`run_simulation_task` raises `PermanentFailure` for an unknown compute job:
correct independent of the policy, since no later attempt can find a row that
was never written.

### Both keys are ported — a place I diverge from the prior report

`bump`'s `enqueue_simulation` sets **both** Procrastinate locks:

```python
queueing_lock=f"simulation:{compute_job_id}",
lock=f"compute-job:{compute_job_id}",
```

The prior report argued against adding a `concurrency_key`, but its codebase
never set `lock`. Here it does, and REQUIREMENTS.md §1 point 2 names this exact
picv-2025 need ("one simulation per compute job") as one of the three reasons
rqueue exists rather than pgqueuer. So both are ported one for one:
`queueing_lock` -> `dedupe_key` with `on_conflict="return_existing"`, `lock` ->
`concurrency_key`. Dropping the second would have quietly removed a guarantee
the deployed code has.

As the prior report notes, the primary idempotency guard is still
`compute.jobs.simulation_id UNIQUE` plus `ON CONFLICT DO NOTHING` — a repeated
POST never reaches `defer` at all. The dedupe key is the queue-layer second
guard. Verified both ways in `test_repository_integration.py` and by hand.

### Queue schema: `task_queue`

`COMPUTE_QUEUE_SCHEMA`, default `task_queue` (rqueue's own default). This
matters more here than the brief implies: on `bump`, `PROCRASTINATE_SCHEMA`
was **`compute`**, i.e. Procrastinate's tables shared picv-2025's own business
schema. rqueue's §7 rule is that queue tables never live in an application's
business schema, so this is a move, not just a rename.
`test_worker_integration.py` asserts `compute` holds exactly `{jobs}` and
`task_queue` holds rqueue's; confirmed again on a live database by hand.

### Transient classification: `acquire()` was the wrong seam

`_CONNECTION_ERRORS` was only applied where a connection is *borrowed*. That is
not where a database restart under a running simulation lands — a simulation
holds no connection for its duration, it borrows one per progress write, so the
failure lands on the statement. `TRANSIENT_RETRY` retries `TransientInfraError`
and nothing else, so an untranslated asyncpg error turned a recoverable outage
into a dead job.

Reproduced against a real database, and the answer was not what the finding
assumed. asyncpg reports this two different ways:

```
$ kill the backend with a statement in flight
  ConnectionDoesNotExistError  <- PostgresConnectionError   covered: True

$ issue a statement on a connection whose backend already died
  InterfaceError("connection is closed")                     covered: False
```

So widening the *placement* alone would have missed the second case, which is
the likelier one: the pool hands out a connection, the backend dies, the next
statement finds it gone. `InterfaceError` had to be added — but it cannot
simply be added to `_CONNECTION_ERRORS`, because asyncpg raises the same class
for a programming error:

```
$ conn.fetchrow("SELECT $1::int, $2::int", 1)
  InterfaceError: the server expects 2 arguments for this query, 1 was passed
```

Translating *that* to `TransientInfraError` would spend a job's entire retry
budget re-running a bug that cannot succeed. `db.transient_connection_errors()`
therefore translates `InterfaceError` only when the connection is actually
gone; a programming error leaves the connection open and propagates unchanged.

Writing the integration test for this found a flaw in my own first version of
that check. When a pooled connection's backend dies, asyncpg terminates the
connection and takes the proxy back, after which *every* method on the proxy
raises — `is_closed()` included:

```
asyncpg.exceptions.InterfaceError: cannot call Connection.is_closed():
connection has been released back to the pool
```

`_connection_is_gone()` treats a proxy that cannot answer the question as gone,
which is the only sound reading. The distinction survives, because a connection
that merely rejected a malformed call answers `False` and keeps working.

Applied to every repository function that runs on a caller-supplied connection —
`fetch_by_id`, `mark_started`, `record_progress`, `get_current_step`,
`record_failure`, `fail_job`, `complete_job`. That is a statable rule rather
than a list: those are exactly the functions a running attempt drives. The
API-side readers manage their own `acquire()` and already have their own error
handling, unchanged from `bump`.

### Finalization is part of the run, not after it

`complete_job` sat outside `run_simulation_task`'s `try`, so a failure there
never reached `_record_failure`. rqueue still retried correctly — the exception
propagates and `TRANSIENT_RETRY` applies, and `output_store` does raise
`TransientInfraError` for a MinIO outage — but nothing wrote "Retrying after
transient error" to `compute.jobs`, so nobody watching saw a retry in progress.
`crash_recovery_e2e.sh` scenario 3 stops MinIO at the last pipeline step and
asserts on exactly that text, so it was asserting on something this code could
not produce. Reconciliation does not help here: the queue never gives up.

`complete_job` now has its own failure-recording path. The interesting part is
the partial-failure analysis, because `complete_job` does two things:

| Where it fails | What is left behind | What is now reported |
| --- | --- | --- |
| MinIO upload | nothing written to `compute.jobs`; objects are keyed by simulation id, so the retry overwrites | "Retrying after transient error" |
| the `UPDATE`, before commit | transaction rolled back; `compute.jobs` still `running`; MinIO objects orphaned until the retry rewrites them | "Retrying after transient error" |
| the connection drops *at* commit | genuinely ambiguous — the row may be `completed` | nothing: see below |

The third row is the trap. The caller cannot tell whether its commit landed, so
it reports a failure for a job that may have finished. Both branches of
`record_failure` now carry `AND status <> ALL('{completed,failed}')` — the same
guard `_fail_exhausted` had on `bump` — so a job that reported its own outcome
is never overwritten by a later report of failure. Tested directly.

### At-least-once means a completed job can come back

rqueue's own docs are explicit ("Delivery is **at least once**... handlers and
their external side effects must be idempotent"), and this handler was not. A
worker that dies between `complete_job`'s commit and rqueue's finalization gets
the job redelivered; `run_simulation_task` would re-run the whole simulation,
and `mark_started` would flip a finished `compute.jobs` row back to `running`
for everyone watching it.

`run_simulation_task` now short-circuits on `status == 'completed'`: it logs,
removes the workspace (the one step the dead attempt may not have reached), and
returns, letting rqueue mark the job succeeded. Only `completed` short-circuits.
A retry after a real failure still sees `running` — `record_failure`'s retry
branch deliberately leaves the status alone — so the legitimate retry path is
untouched, which the existing transient-retry tests confirm.

### Reconciliation: the half of the reaper that had no replacement

This is the change the review pass forced, and it is the important one.

`bump`'s `reap_stalled_jobs_task` did **two** jobs. It found jobs whose
heartbeat had gone stale and either requeued them or, when
`job.attempts >= MAX_ATTEMPTS`, gave up — and giving up meant *both*
`finish_job_by_id_async(status=FAILED)` on the queue row *and* `_fail_exhausted`
on `compute.jobs`:

```python
def _fail_exhausted(compute_job_id: str) -> None:
    ...
    if row is None or row["status"] in {COMPLETED, FAILED}:
        return
    repository.fail_job(conn, job_uuid, row["simulation_id"], CRASH_BUDGET_EXHAUSTED_ERROR)
```

Deleting that task was right for the queue-state half: rqueue's `Worker._tick`
calls `Storage.recover_expired_leases` on every poll, and fenced leases are
strictly better than a heartbeat reaper — the recovering write clears
`lease_token`, so the stale holder's own later write fails with `LeaseLost`
instead of racing. I stand behind that deletion.

But the `compute.jobs` half had no replacement, and I did not notice.
`recover_expired` is one pure-SQL statement:

```sql
UPDATE {schema}.jobs AS j
SET state = CASE WHEN e.cancel_requested THEN 'cancelled'
                 WHEN e.attempt >= e.max_attempts THEN 'failed'
                 ELSE 'pending' END,
    error_type = ... 'LeaseExpired' ...
```

It never calls the handler back. So a worker crash that spends the last attempt
left `task_queue.jobs.state = 'failed'` beside `compute.jobs.status = 'running'`,
with no code path anywhere that would ever correct it: the API, `/events` and
the web app would show that simulation as running forever.

**Why a reconciler and not three patches.** The same shape is reachable from
more than lease expiry. `complete_job` runs *outside* `run_simulation_task`'s
`try`, so a MinIO or database failure during finalization propagates without
`_record_failure` running at all. `_record_failure` itself deliberately
swallows its own errors, so that a second outage cannot replace the failure it
is reporting — which means a database outage there also ends the run with
nothing written. Each of those could be patched at its call site, and the next
one would still be waiting. The condition worth writing against is not "which
way did the write get skipped" but **"the queue is finished with this job and
`compute.jobs` does not know"**.

`repository.reconcile_terminal_jobs` is that condition, as one statement:

```sql
UPDATE compute.jobs AS j
SET status = 'failed', details = ..., error = format($3, COALESCE(q.error_type, q.state)),
    finished_at = COALESCE(j.finished_at, q.finished_at, now()), updated_at = now()
FROM task_queue.jobs AS q
WHERE q.queue = $4 AND q.task = $5
  AND q.state = ANY('{failed,cancelled}') AND q.finished_at < $7
  AND j.id = (q.payload->>'compute_job_id')::uuid
  AND j.status <> ALL('{completed,failed}')
RETURNING j.id, j.simulation_id
```

Details that are deliberate:

- **`'succeeded'` is excluded.** The queue only records success after
  `run_simulation_task` returned, which it cannot do before `complete_job` has
  committed. A succeeded job that still looks unfinished is not a state this
  code can reach, and treating one as failed would be a lie.
- **`j.status <> ALL('{completed,failed}')` is the same guard `_fail_exhausted`
  had.** A run that reported its own outcome is never overwritten. It also
  makes the pass idempotent and safe to run from two workers at once: the guard
  is evaluated under the row lock the `UPDATE` takes, so the second pass sees
  the first one's result. Tested both ways.
- **`RETURNING` + `NOTIFY` in the same transaction.** A watching SSE stream is
  woken by the reconciliation exactly as it is by a live run, so a stuck
  browser learns within a second instead of waiting out the 30-minute SSE cap.
  Confirmed by hand with a `LISTEN` session (below).
- **`finished_at` comes from the queue row**, not from `now()`: the truthful
  finish time is when the queue gave up, not when the reconciler noticed.
- **The schema name is interpolated, everything else bound.** PostgreSQL has no
  bind parameter for an identifier. The only value ever passed is
  `rqueue.Queue.schema`, which rqueue validated against `[a-z_][a-z0-9_]*` when
  the queue was constructed, so the interpolated name is byte-identical to the
  schema rqueue itself created. `repository` still learns nothing about the
  queue: schema, queue name and task name all arrive as arguments, the same way
  `create_or_get_job` takes `defer`.

**Interval: 60s, against the sweep's hour.** The two clean up different things.
The sweep reclaims disk from jobs that are *already reported* failed, where an
hour of delay is invisible to everyone. This pass is what ends a user-visible
stuck status, so its delay is felt directly. The pass is one indexed statement
over jobs the queue has already finished (`jobs_queue_state_idx` covers
`queue, state`), so a minute is cheap.

**Grace: 5 minutes.** A terminal queue row already implies no worker holds the
lease, so in principle nothing else can be writing. The grace covers the one
case where that reasoning is not airtight — a worker wedged long enough to lose
its lease, whose own write of the outcome can still land after rqueue failed the
row underneath it. Five minutes is comfortably longer than any such write and
costs nothing, since this only ever runs on jobs that are already over. It also
keeps the pass clear of `crash_recovery_e2e.sh` scenario 1, which crashes a
worker *with attempts remaining* — that job goes back to `pending`, which this
never touches.

The pass runs in the worker process, next to the sweep, because the worker is
the process that owns recovery: this exists to repair what rqueue's own lease
recovery leaves behind. `repository.fail_job` survives as a primitive but is now
exercised only by tests — reconciliation writes its terminal state in the same
set-based statement that finds the candidates, so it cannot go through a
single-row helper.

### Abandoned kernel threads: fenced in the database

The kernel is synchronous and runs via `asyncio.to_thread`. rqueue cancels a
handler's *coroutine* when its heartbeat finds the lease gone
(`_heartbeat_loop` -> `lease_lost.set()`, `handler_task.cancel()`), but Python
cannot kill the thread underneath. That thread holds a live reference to the
event loop through `on_progress`, so it can keep writing `compute.jobs` and the
shared work directory for a job another worker has taken over. This is a **new**
exposure: Procrastinate's task was synchronous, with no background thread able
to outlive a cancelled coroutine, so there is nothing to wave off as
pre-existing.

Note what rqueue does *not* offer here: `context.cancel_event` is set only for a
*requested* cancellation. On lease loss it sets a private `lease_lost` and
cancels the task, so the application cannot observe lease loss through
`TaskContext` at all — only through its own `CancelledError`.

**Why the first version was not good enough.** The bounded fix (a Python flag
set on cancellation, checked by `on_progress`) closes a check-then-write gap by
narrowing it, not by removing it, and the review pass named the case that makes
that insufficient: a stale write does not merely record stale progress, it can
set `status` back to `running` on a job **`reconcile_terminal_jobs` has already
correctly marked `failed`** — silently undoing the repair this same change
built. Reconciliation's guarantee would not hold under the very condition that
produces it. That is not a residual race worth documenting; it is a hole in a
fix, and it justified reopening the DDL question.

**The fence.** `compute.jobs` gains one column:

```sql
owner_attempt integer            -- NULL until the first attempt claims the row
ALTER TABLE compute.jobs ADD COLUMN IF NOT EXISTS owner_attempt integer;
```

`mark_started` claims the row for `context.attempt` and marks it running in one
statement, and returns whether the claim was won:

```sql
UPDATE compute.jobs SET status = 'running', owner_attempt = $3, ...
WHERE id = $4 AND (owner_attempt IS NULL OR owner_attempt <= $3)
RETURNING id
```

Every write that attempt makes afterwards carries its own attempt number **in
the same statement as the write**, which is the whole point — a check followed
by a separate write is exactly the shape that could not close this:

```sql
-- record_progress
WHERE id = $8 AND owner_attempt = $9 AND status <> ALL($10::text[])
-- record_failure (both branches), complete_job
WHERE id = $n AND owner_attempt = $m [AND status <> ALL(...)]
```

Two predicates, because they catch different things:

- **`owner_attempt = $n`** refuses a write from a *superseded* attempt: a thread
  abandoned by attempt 1 cannot scribble over what attempt 2 is doing.
- **`status <> ALL('{completed,failed}')`** refuses a write to a job that is
  already finished. This is the one that catches the reconciliation case,
  because there the abandoned attempt is *still the row's owner* — the attempt
  fence alone would let it through. `complete_job` deliberately does **not**
  carry this second predicate: a run that genuinely produced a result should
  still be able to record it, and only the owning attempt can reach it at all.

A refused write is not an error, it is the fence working. `record_progress` and
`mark_started` return a boolean rather than raising. `on_progress` treats a
refusal as the signal to stop, raising `AbandonedAttempt` so the kernel unwinds
and the thread ends instead of burning a core on work nobody will read —
`tsdhn.engine` puts no `try` around `on_progress`, so the exception really does
unwind. The cancellation flag is kept alongside it, because it usually stops the
thread a step *earlier* than a refused write would; it is now an optimisation
rather than the guarantee.

`run_simulation_task` also stands down if `mark_started` fails to claim: a newer
attempt owns the row, so every write it made from that point would be refused
anyway.

Writing the tests for this proved the fence bites: three pre-existing repository
tests started failing because they wrote without ever claiming the row, which is
precisely the thing that is now impossible.

### The workspace is fenced separately, with `flock`

The `owner_attempt` fence protects `compute.jobs`. It does nothing for the
files, and the fifth review round was right that this is the more serious half:
the workspace is keyed by simulation id, not by attempt, so an abandoned thread
mid-step keeps writing checkpoints that a replacement attempt may resume from.
A corrupted checkpoint yields a *wrong scientific result*, silently, rather than
an error — a worse failure than any of the status races already closed.

I went looking for a bounded fix and found one, so this is fixed rather than
disclosed.

**Why `flock` and not a lock file with an attempt number in it.** A plain marker
file cannot answer the question that matters, which is not "who owned this last"
but "is that owner still alive". A marker left by a worker that was SIGKILLed
looks exactly like one left by a thread still writing, and those two need
opposite answers: the first must resume (that is the whole point of checkpoint
resume, and what `crash_recovery_e2e.sh` scenario 1 asserts), the second must
not. A staleness heuristic on the marker's mtime does not fix it either, because
the dangerous window is a long step during which no progress callback fires, so
a live owner's marker goes stale exactly when it must not.

`flock` answers the real question, because of how the kernel releases it:

```
first flock: acquired
second flock in SAME process: refused (BlockingIOError)
flock from another THREAD: refused
after the holder closed its fd: acquired
```

It is held against the open file description, so a second attempt is refused
even from another thread of the same process — which is precisely the zombie
case, and what a `WORKER_CONCURRENCY` above one makes possible. And the kernel
drops it when the holding **process** dies, SIGKILL included, so a crashed
worker leaves the workspace resumable and scenario 1 keeps working.

Four details are load bearing:

- **The lock is a sibling of the workspace, not inside it.**
  `prepare_simulation_workspace` does `shutil.rmtree(work_dir)` whenever a run
  starts without resuming, which would delete a lock file kept inside.
- **The claim outlives the coroutine, and spans the upload.** It carries two
  shares — one given back by the kernel thread, one by the coroutine after
  `complete_job` — and the descriptor closes only when both have. Neither
  holder can be cancelled, and a cancelled coroutine ends while the thread is
  still writing, so "whoever finishes last closes it" is the only rule that
  works. A single owner cannot be correct here in either direction: releasing
  with the coroutine hands the workspace away mid-write, and releasing with the
  kernel leaves the upload unprotected.
- **Removal takes the lock before it removes anything.** See below; `unlink` on
  a locked file is a trap, not a tidy-up.
- **`resume` is evaluated under the lock.** "Are there checkpoints to resume
  from" is otherwise a question about a directory someone else may be halfway
  through writing.

A refused claim raises `TransientInfraError`, so rqueue's own backoff does the
waiting. That is the right mechanism rather than a new one: the abandoned thread
unwinds at its next progress write, which the database fence refuses, so the
workspace frees itself and the retry succeeds.

**What is still not covered**, stated plainly rather than left implicit:

- A thread that never reaches another progress callback holds the workspace
  until it finishes on its own. A replacement can exhaust its three attempts
  waiting and fail. That is a visible, bounded failure instead of silent
  corruption — the trade being made deliberately.
- `flock` is a single-machine primitive. Two workers on different hosts sharing
  one network volume are not protected. The compose deployment runs one worker
  against a local volume, so nothing shipped today is exposed; a multi-host
  deployment would need per-attempt workspaces or a real distributed lock, which
  is a design change and not this task's.

Both are in the module docstring as well as here.

### Periodic sweep: a plain asyncio task

`sweep_abandoned_work_dirs_task` (hourly `@app.periodic`) becomes
`tasks.sweep_abandoned_work_dirs()` (one idempotent pass) driven by
`tasks.run_periodic_sweep(stop_event)`, an `asyncio.Task` the worker process
owns. It and the reconciler share one `_run_periodically` helper, so "a failed
pass is logged and the loop continues" is written once — a database outage is
exactly when jobs get stranded, so it must not be the thing that stops the pass
which unstrands them. The prior report's judgement, reused: `rqueue.Scheduler`'s occurrence-key
machinery earns its complexity when replicas must not double-fire a *job*, and
an `rmtree` of already-failed work directories is idempotent and harmless to
run twice. A failed pass is logged and the loop continues (tested).

The `rmtree` calls go through `asyncio.to_thread`, as does
`complete_job`'s MinIO upload — the upload was previously on a synchronous
Procrastinate task and would otherwise stall the worker's event loop, and with
it rqueue's heartbeat, for the whole upload.

### Task registration is explicit, on both processes

rqueue's `Queue` needs a pool at construction, so `@queue.task(...)` at import
time is not available; `register_tasks(queue)` calls `queue.register(...)` with
the same arguments instead. Both the API and the worker call it, because
`Queue.build_insert` reads the registration to stamp the task's `max_attempts`
and timeout onto the row — an unregistered producer would silently enqueue
jobs with the queue's defaults rather than `TRANSIENT_RETRY`'s. That is
asserted in `test_tasks.py`.

`RUN_TIMEOUT_SECONDS` is explicitly `None`: a simulation is tens of minutes
with no meaningful upper bound, and lease recovery, not a timeout, is what
reclaims a run whose worker died.

### SSE: a real `LISTEN` rewrite

`bump` genuinely has `NOTIFY`, so this was real work rather than the no-op the
prior run found. `job_events` now:

- opens a **dedicated** connection via `db.connect()`, not a pooled one. This
  is deliberate and matches what the psycopg version did: a stream can hold it
  for `SSE_MAX_DURATION` (30 minutes), and a handful of watching browsers on
  the pooled path would starve every other route.
- registers `connection.add_listener(channel, on_notify)`; the callback (which
  asyncpg runs on the loop) does `wakeups.put_nowait(None)` on a one-slot
  `asyncio.Queue`, suppressing `QueueFull`.
- `_wait_for_notification` waits with `asyncio.timeout(_KEEPALIVE_SECONDS)`,
  returns `False` on the timeout, and drains any burst behind the first item so
  one re-read covers them all.
- keeps the existing loop exactly: re-read status on every wakeup *and* on the
  keepalive timeout (a notification can race the wait), emit on change, exit on
  terminal state, `": keepalive"` when nothing changed and nothing arrived,
  deadline via `anyio.current_time()`.

---

## The one place the brief contradicts itself: `queue_migrate.py`

The brief says "do not touch `queue_migrate.py`" (stage 2 owns it) **and**
"Remove `procrastinate`". Those cannot both hold: `api/queue_migrate.py`'s
first import is `import procrastinate`, so removing the dependency leaves a
module that cannot be imported, breaks `mypy --strict`, breaks two integration
tests, and breaks the `tsdhn-procrastinate-migrate` entry point that
`docker-compose.yml`, `mise run db:migrate` and `scripts/integration.sh` all
invoke.

I resolved it toward a working tree: **deleted `api/queue_migrate.py` and its
entry point**, and replaced its three invocations with

```
rqueue --database-url "$COMPUTE_DATABASE_URL" --schema "$COMPUTE_QUEUE_SCHEMA" migrate
```

(`--schema` is a *global* flag before the subcommand, not a `migrate` flag —
confirmed against `cli.py` and by running it.)

**What this does not do, and is still stage 2's problem:** nothing decides
what happens to an already-deployed Procrastinate schema in `compute` or to
its in-flight rows. There is no migration path, no data move, and no
detection that one exists. A deployment carrying live Procrastinate jobs will
strand them. Stage 2 also still owns rqueue's own least-privilege role grants
for `task_queue`.

I also dropped `test_procrastinate_schema_migration_is_repeatable` (it tested
the deleted module) and rewrote `test_web_role_cannot_read_compute_queue_tables`
into `test_web_role_cannot_read_the_queue_tables`, which now asserts the web
role cannot `SELECT` from `task_queue.jobs`. That security floor is preserved,
not dropped — the web grants never mention the queue schema and the schema is
owned by the migration role.

---

## Dependencies

Added with `uv add` (not hand-edited), then `uv sync --all-packages`:

- `asyncpg>=0.31.0`. Installs and imports on this workspace's Python 3.14.7.
- `rqueue` as a **git dependency pinned to a commit**:

  ```
  uv add --package tsdhn-api \
    "rqueue @ git+https://github.com/totallynotdavid/transactions.git@545d67aa341372c663972427b2b520fcd07faf80"
  ```

  which wrote
  `[tool.uv.sources] rqueue = { git = "https://github.com/totallynotdavid/transactions.git", rev = "545d67aa..." }`
  into `packages/api/pyproject.toml` and
  `source = { git = "...?rev=545d67aa...#545d67aa..." }` into `uv.lock`. No
  `path =` or `directory =` entry for rqueue remains in either file.

  `545d67aa341372c663972427b2b520fcd07faf80` is the tip of that remote's
  `master` (`git ls-remote`), and it is the same commit as the local
  `~/git/transactions` HEAD with a clean working tree — so the pinned content
  is byte-for-byte what every verification below was run against.

Removed: `procrastinate>=3.9.0`.

`psycopg` **stays**, per the brief's rule. `api/migrate.py` and
`api/web_grants.py` — both explicitly out of scope — still import it directly.
I did narrow the extra from `psycopg[binary,pool]` to `psycopg[binary]`:
`psycopg_pool` was imported only by `db.py`, which this change rewrites, and
nothing in the repository imports it now (verified by grep).

`requires-python` for `packages/api` is `>=3.14`, which satisfies rqueue's
`>=3.13`. Confirmed rather than assumed; no floor change.

`pip-audit` is not how this repo audits — `mise run audit` is
`uv audit --locked --preview-features audit-command --no-dev --no-group build`,
and `.github/workflows/security.yml` runs the same. It handles the git
dependency without complaint, so the prior report's `--no-emit-package rqueue`
workaround is **not needed here**:

```
$ mise x -- uv audit --locked --preview-features audit-command --no-dev --no-group build
Found no known vulnerabilities and no adverse project statuses in 47 packages
```

### The container image builds — verified

This section previously recorded a blocker. It is fixed and the finding is
withdrawn; the history is worth keeping, since it is the reason the dependency
is shaped the way it is.

**What was wrong.** The first version of this work used a *path* dependency
(`uv add --package tsdhn-api ~/git/transactions`), because rqueue had no
remote. `deploy/api.Dockerfile` builds with the repo root as its context and
runs `uv sync --frozen --no-dev --package tsdhn-api`, and
`../../../../git/transactions` resolves outside any build context, so the
image could not be built at all:

```
error: Failed to determine installation plan
  Caused by: Distribution not found at: file:///.../git/transactions
```

**What fixed it.** rqueue now has a real remote, and the dependency is a
pinned git reference. Both checks pass:

- The same out-of-tree reproduction that produced the error above — copy
  `pyproject.toml`, `uv.lock` and `packages/` to a directory where the old
  relative path leads nowhere, then `uv sync --frozen --no-dev --package
  tsdhn-api` — now completes, and `rqueue`, `rqueue.migrations` and
  `rqueue.testing` all import from the resulting environment.
- The real image build succeeds:

  ```
  $ podman build -f deploy/api.Dockerfile \
      --build-arg TOOLCHAIN_IMAGE=localhost/tsdhn-toolchain:local \
      -t localhost/tsdhn-api:rqueue-git-check .
  ...
  Building rqueue @ git+https://github.com/totallynotdavid/transactions.git@545d67aa...
     Built rqueue @ git+https://github.com/totallynotdavid/transactions.git@545d67aa...
  Prepared 44 packages in 3m 25s
  ...
  Successfully tagged localhost/tsdhn-api:rqueue-git-check     (exit 0)
  ```

  And inside that image, the command `docker-compose.yml`'s `compute-migrate`
  step actually runs is present, resolved from git at the pinned commit:

  ```
  $ podman run --rm localhost/tsdhn-api:rqueue-git-check \
      sh -lc 'uv run --no-dev rqueue --help'
  usage: rqueue [-h] [--database-url ...] [--schema ...] [-v]
                {migrate,status,readiness,purge,grant-role} ...

  # direct_url.json for the installed rqueue distribution:
  {"url":"https://github.com/totallynotdavid/transactions.git",
   "vcs_info":{"vcs":"git",
               "commit_id":"545d67aa341372c663972427b2b520fcd07faf80",
               "requested_revision":"545d67aa341372c663972427b2b520fcd07faf80"}}
  ```

  (Built against the locally available `localhost/tsdhn-toolchain:local` rather
  than pulling `ghcr.io/totallynotdavid/tsdhn-toolchain:master`; the Dockerfile
  takes that base as a build arg and nothing else about the build differs.)

The check image and the temporary build context were removed afterwards.

**What is still open.** This is a commit pin on a git URL, not a released
version pin. It is no longer machine-specific and no longer blocks a build,
but it means every consumer resolves rqueue by cloning a GitHub repository at
one commit: there is no version range, no index, and an upgrade is a manual
hash bump. Once rqueue cuts an actual release this should become an ordinary
`rqueue>=0.2` specifier. Tracked as follow-up 1.

---

## Verification

Everything below was re-run unchanged after the rqueue dependency moved from a
local path to the pinned git URL, with identical results.

### Static

```
$ mise run lint
uv run ruff check --select E,F,W,I,B,UP,S,SIM,RUF .   -> All checks passed!
uv run ruff format --check .                          -> 94 files already formatted
uv run mypy --strict packages                         -> no issues found in 92 source files

$ mise x -- uv run bandit -r packages -lll --skip B101   -> High: 0
$ bun run gen:client && git diff --stat libs/api-client  -> no drift
```

Three `# noqa: S608` in tests, where the queue schema name is interpolated into
a `SELECT` (PostgreSQL has no bind parameter for an identifier). Production
code has no interpolated SQL other than the `NOTIFY` channel, which is a uuid
hex and was already that way.

### Test suite

```
$ mise x -- uv run pytest -n auto -q -m 'not integration'
230 passed, 14 skipped        (skips are golden/parity/GMT, unrelated)

$ mise x -- uv run pytest packages/api/tests -q -m integration
42 passed, 91 deselected

$ bash scripts/integration.sh     # full script: both migrations, web, python, web tests
42 passed (python)  +  2 passed (web)
```

The last one exercises the changed `scripts/integration.sh` end to end,
including the new `rqueue ... migrate` step against a disposable database.

New/rewritten test coverage worth naming:

- `test_worker_integration.py` (16 tests, real PostgreSQL, real `rqueue.Worker`
  via `drain()`): a queued simulation runs to `succeeded` with progress,
  outputs and terminal state correct **and the kernel demonstrably on an
  `rqueue-test-worker` executor thread**; a pipeline error fails terminally on
  attempt 1 (proving `retry_on` is an allowlist); a `TransientInfraError` is
  *rescheduled* rather than failed, with `compute.jobs` still `running` and
  "Retrying after transient error"; a job whose compute row is missing becomes
  a `PermanentFailure`; an undecodable payload fails as `PayloadDecodeError`
  before the handler runs; the queue tables stay out of `compute`. Two more
  cover reconciliation, described next.
- **The reconciliation gap, reproduced end to end**
  (`test_a_crash_that_exhausts_the_lease_budget_is_reconciled`). A job is
  submitted through the real producer path, put on its last attempt, then
  claimed with a sub-second lease by a worker that writes
  `compute.jobs = running` exactly as `run_simulation_task` does and never
  comes back — rqueue allows sub-second leases specifically so a test can drive
  real expiry. A live worker's `drain()` then recovers the expired lease. The
  test asserts, in order: the queue row is `failed`/`LeaseExpired`; the handler
  was **never re-invoked** (the stubbed `run_simulation` calls `pytest.fail` if
  it is, which is the whole point — recovery is a SQL update); `compute.jobs`
  is *still* `running`, i.e. the gap is real and reached; then after one
  reconcile pass it is `failed` with the reconciled error text and a
  `finished_at`; and a second pass returns `[]`.

  Verified to fail without the fix: with `reconcile_terminal_jobs` stubbed to
  return `[]`, the test fails at exactly the intended line —
  `AssertionError: assert 'running' == 'failed'`.

  A second test proves the guard holds the other way: a job that ran to
  `completed` is left alone even when its queue row is forced to
  `failed`/`LeaseExpired` underneath it. A third puts a queue row with a
  non-uuid payload beside a genuinely stuck job and asserts the stuck job is
  still reconciled — it fails with the real
  `InvalidTextRepresentationError` if the regex guard is removed.
- **Finalization failure** (`test_a_transient_finalization_failure_is_reported_as_retrying`):
  the kernel succeeds, MinIO raises `TransientInfraError`, and the test asserts
  the queue rescheduled the job *and* that `compute.jobs.details` reads
  "Retrying after transient error (TransientInfraError)" — the string
  `crash_recovery_e2e.sh` scenario 3 watches for while MinIO is stopped — and
  that the workspace survived for the retry to resume from.
- **Redelivery** (`test_a_redelivered_completed_job_is_not_run_again`): a job is
  run to `completed`, then its queue row and attempt record are put back the way
  a worker dying before finalization leaves them. The stubbed kernel calls
  `pytest.fail` if reached. The job is not re-run, `finished_at` is unchanged,
  and — the part that actually hurt — `mark_started` does not flip it back to
  `running`.
- **Connection death mid-statement**
  (`test_a_backend_killed_mid_statement_reports_as_transient`): the test kills
  its own backend with `pg_terminate_backend` and asserts `record_progress`
  raises `TransientInfraError`, which is the class `TRANSIENT_RETRY` retries.
  Four unit tests in `test_db.py` pin the four cases the translation
  distinguishes, including a programming error that must *not* be disguised as
  an outage.
- **Overwrite guard** (`test_record_failure_never_overwrites_a_finished_job`):
  both branches of `record_failure` are called against a `completed` row and
  leave it exactly as it was.
- **Abandoned attempt**
  (`test_an_abandoned_attempt_stops_its_kernel_thread_from_writing`): a real
  cancellation of a real handler with a real thread still in `run_simulation`.
  The write from before the cancellation stands, the write after it is refused,
  and the refusal surfaces in the thread as `AbandonedAttempt`.
- **The attempt fence**, two integration tests against real PostgreSQL.
  `test_a_stale_attempt_cannot_undo_a_reconciled_failure` drives the exact
  scenario the third review round named: claim with a sub-second lease, mark
  started, let the lease expire, let a worker recover it, reconcile the job to
  `failed`, then make the stale write the still-running attempt would make. The
  write returns `False`, the status stays `failed`, `step` is untouched and the
  reconciled error text survives.
  `test_a_superseded_attempt_cannot_write_over_the_newer_one` covers the other
  predicate: attempt 2 takes the row, and attempt 1 can neither write to it nor
  claim it back. Both fail if either predicate is removed from the `UPDATE`.

  Three pre-existing repository tests had to start claiming the row before
  writing to it, which is itself evidence the fence is real rather than
  decorative.
- **Stand-down accounting**
  (`test_a_stand_down_is_not_counted_as_a_failed_job`): a real worker whose
  kernel is superseded mid-run leaves the queue row `cancelled`, not `failed`,
  and reconciliation then repairs `compute.jobs`. Fails with
  `assert 'failed' == 'cancelled'` without the fix.
- **Operator retry** (`test_an_operator_retry_of_a_failed_job_can_still_start`):
  a genuinely failed job is retried through `rqueue.Admin.retry_job` and runs to
  `completed` -- the behaviour that would break if `mark_started` also refused
  `FAILED` rows.
- **Orphaned result** (`test_complete_job_reports_a_result_it_could_not_record`):
  a superseded attempt's `complete_job` returns `False` and logs the bucket and
  key it uploaded, instead of no-oping in silence.
- **Transient classification** (`test_transient_classification_follows_the_sqlstate_class`,
  13 parametrised cases): every SQLSTATE class on the transient side is
  recognised -- including `TooManyConnectionsError`, the one an exception-type
  allowlist missed -- and every application-bug class on the permanent side is
  left alone. A companion test drives pool exhaustion through `db.acquire()`.
- **The atomic claim** (`test_a_claim_cannot_reopen_a_completed_job`,
  `test_a_reclaimed_job_does_not_keep_the_previous_failure`): a redelivered
  attempt cannot reopen a `completed` row, and a reclaimed row does not keep the
  previous attempt's `error` and `finished_at` beside its new `running`.
- **The workspace lock**, seven tests in `test_tasks.py` with real threads: a
  live owner's workspace is refused to a second attempt *from another thread of
  the same process*; the claim survives the coroutine's cancellation, which is
  why the kernel thread holds a share of its own; the claim stays held after the
  kernel returns and frees only on its last share, which is what protects the
  upload; over-releasing is harmless; a fresh workspace reports nothing to
  resume and keeps its lock file outside the directory the engine deletes;
  removal takes the lock with it, idempotently; and a workspace whose lock is
  still held is left for the next sweep rather than force-removed. Both
  sixth-round fixes have negative checks: a single-share claim fails two of
  these with `DID NOT RAISE`, and an unlink-first `remove_workspace` fails
  another with `assert True is False`.
- `test_repository_integration.py` (15 tests): both rows commit together; a
  rolled-back producer leaves neither `compute.jobs` nor `task_queue.jobs`; a
  repeated submission enqueues once; concurrent submissions create one job;
  the `$n::text::jsonb` / `::text` round trip preserves nested JSON and
  `COALESCE` leaves unmentioned columns alone; a real listener proves
  `mark_started`'s NOTIFY arrives only with a committed row.
- `test_tasks.py` uses `rqueue.testing.RecordingQueue`, so the enqueue call is
  validated by the real `Queue.build_insert` (a typo'd task name fails the
  test) with no database.

### By-hand run against a real database

Ran `tsdhn-api` (uvicorn, port 8099) and a real worker process against a real
PostgreSQL 18.6 database (`tsdhn_manual`, both schemas applied by the two
migration commands above) and a real MinIO container.

**What was stubbed and why.** Only `tsdhn.engine.run_simulation` — replaced,
from a scratch-directory driver script that is not in the repository, by a stub
that sleeps, calls `on_progress` for the eight real pipeline steps, and returns
a real `SimulationResult` with one output file. This host has neither the
Fortran model binaries (no `ifort`/`gfortran`, and `ttt_client`/`libttt.so.4`
come from a private GitLab SDK) nor a Ghostscript that GMT 6.6 can drive — the
prior report hit and documented that same wall, working around it by extracting
binaries from a container image plus a `gs` wrapper. **Everything this task
changed is the production code path in the run below**: the asyncpg pool,
rqueue's enqueue-in-the-producer-transaction, claim/lease/heartbeat/finalize,
the `asyncio.to_thread` hop, the progress writes and their NOTIFY, the SSE
listener, and the MinIO upload. What it does **not** re-prove is that the
scientific pipeline still runs; nothing in this change touches it, and the
prior report's full 17-minute real-toolchain run stands as that evidence.

Confirmed:

- `GET /api/v1/health` -> `{"status":"healthy","database_connected":true,
  "storage_connected":true}` — the asyncpg pool and the threaded MinIO probe.
- `POST /api/v1/jobs` -> `201 {"status":"queued"}`, and one row in
  `task_queue.jobs`:
  `task=api.run_simulation, queue=simulations, max_attempts=3,
  dedupe_key=simulation:<id>, concurrency_key=compute-job:<id>`.
- **The worker claimed it within one second of the POST** (`state=leased`,
  `worker_id=tsdhn-worker-zeus-3386123`) — that is the NOTIFY wake-up on
  rqueue's `LISTEN` connection, and the worker log carries no
  "could not LISTEN ... falling back to polling" warning.
- **SSE reports state through real pushes, not polling.** With the stub pacing
  a step every ~1.5s, `GET /api/v1/jobs/{id}/events` emitted (timestamps are
  the client's):

  ```
  10:36:31.681  queued                          Queued for simulation worker
  10:36:33.194  running  fault_plane   1/8      Processing fault_plane
  10:36:34.691  running  deform        2/8      Processing deform
  10:36:36.200  running  tsunami       3/8      Processing tsunami
  10:36:37.700  running  maxola        4/8      Processing maxola
  10:36:39.208  running  ttt_inverso   6/8      Processing ttt_inverso
  10:36:40.707  running  point_ttt     7/8      Processing point_ttt
  10:36:42.215  running  copy_ttt_pdf  8/8      Processing copy_ttt_pdf
  10:36:42.244  completed copy_ttt_pdf 8/8      Simulation completed successfully
  ```

  Events land ~1.5s apart, tracking the writes. `_KEEPALIVE_SECONDS` is 20, and
  **no `": keepalive"` line appeared** — so every one of those was delivered by
  `add_listener`, not by a timeout re-read.
- Terminal state: `task_queue.jobs` `state=succeeded, attempt=1,
  error_type=NULL, duration=00:00:10.57`; `compute.jobs` `status=completed,
  step_index=8/8, result_bucket=tsdhn-results,
  result_key=simulations/<id>/metadata.json`. MinIO holds `metadata.json` and
  `outputs/calculation.json`. The work directory under `TSDHN_JOBS_DIR` was
  removed. `GET /jobs/{id}/outputs` lists the output without leaking its
  storage key, and the presigned redirect downloads the real bytes.
- Idempotency: a duplicate POST returned the same job and left exactly one
  `task_queue.jobs` row; a POST with the same `simulation_id` and different
  input returned `400`.
- Lease heartbeating under a long handler: sampled mid-run at
  `heartbeat age=8.06s, lease left=51.94s` against the 60s lease — the
  `to_thread` hop leaves the loop free for rqueue's heartbeat task.
- **SIGTERM.** Sent to the worker process mid-run: `worker.stop()` gave the
  in-flight job the 30s `shutdown_timeout` grace (the stub sleeps in a thread
  and cannot be interrupted), then handed the lease back — the row went to
  `pending, attempt=1, error_type=WorkerShutdown`, not left leased and not
  lost. Process exited in 32.5s, i.e. the grace window, not a hang. A restarted
  worker then picked it up and finished it: `succeeded, attempt=2`, with
  `job_attempts` reading `1 -> retry, 2 -> succeeded` and the API reporting
  `completed 8/8`.

Torn down afterwards: MinIO container removed, `tsdhn_manual` dropped, the
`tsdhn_app` role dropped, no processes left.

### By-hand run of the reconciler

The integration tests drive `reconcile_terminal_jobs` directly; this checks the
other half — that `api/worker.py` actually starts the loop in a real process.

Seeded a real local database with the exact state lease recovery leaves behind
(`compute.jobs.status = 'running'`, started two hours ago; a `task_queue.jobs`
row for `api.run_simulation` with `state = 'failed'`, `attempt = 3`,
`max_attempts = 3`, `error_type = 'LeaseExpired'`, finished an hour ago), then
started the real `tsdhn-worker` entry point against it — no simulation, no
MinIO, nothing stubbed:

```
15:20:51,462 - api.worker    - INFO    - simulation worker serving queue simulations
15:20:51,470 - api.core.tasks - WARNING - compute job 1111...1111 was terminal in the
                                          queue but still unfinished; status reconciled
                                          to failed
```

Eight milliseconds after startup, on the loop's first pass. The row afterwards:

```
status      | failed
details     | Failed - reconciled from the task queue
error       | Simulation stopped without reporting a result;
              status reconciled from the task queue (LeaseExpired)
started_at  | 2026-09-05 13:20:43+00
finished_at | 2026-09-05 14:20:43+00      <- the queue's finish time, not now()
```

Repeated with a `psql` session holding `LISTEN tsdhn_job_<hex>` on the
simulation's channel for the duration:

```
Asynchronous notification "tsdhn_job_33333333333343338333333333333333"
received from server process with PID 3475782.
```

So a browser watching `/events` on a stranded simulation is pushed the
correction rather than waiting out the SSE cap. The seeded rows, both schemas
and the `tsdhn_app` role were dropped from the shared local cluster afterwards.

### One local-environment note

This machine's port 5432 is held by **rqueue's own** mise cluster
(`~/git/transactions/.data/postgres`), so picv-2025's `mise run db:start` could
not start its cluster and the suite could not find role `tsdhn`. I created a
`tsdhn` superuser role and a `tsdhn` database on the running cluster so the
disposable-database fixtures work, and **left them in place** so the suite stays
runnable. To undo:

```
psql -h 127.0.0.1 -p 5432 -U rqueue -d postgres -c 'DROP DATABASE tsdhn'
psql -h 127.0.0.1 -p 5432 -U rqueue -d postgres -c 'DROP ROLE tsdhn'
```

The real fix is to give the two projects different ports (the prior report put
picv's cluster on 5433 for the same reason). Not done here: it is a
`mise.toml` / `conftest.py` change with no bearing on the driver swap.

---

## Review findings

Two review passes. Everything real is fixed. Where I disagreed I say so with
the evidence rather than quietly complying, and where a fix is partial I say
which part is missing.

### First pass

#### The reconciliation gap — real, and the significant one

Fixed as described under "Reconciliation: the half of the reaper that had no
replacement". The review's own finding 3 (lease exhaustion), and its gate-B
findings 1 and 3 (a MinIO failure during finalization, and a `record_failure`
write that itself fails) are one condition seen from three directions, and are
closed by one pass rather than three patches. Reproduced end to end in a test
that fails without the fix.

#### `COMPUTE_QUEUE_SCHEMA` reached only the migration step — real

`compute-migrate` was given `COMPUTE_QUEUE_SCHEMA`; `api` and `worker` were
not. Setting it in `.env` therefore migrated one schema and pointed the running
processes at another (their Python-side default, `task_queue`), and the failure
would have shown up as `relation "…jobs" does not exist` at the first enqueue —
after a green migration step. Both services now receive it.

`COMPUTE_QUEUE` had the same passthrough hole and is now passed too. That one
could not actually diverge — no service reads it but `api` and `worker`, and
both defaulted identically — so it is a usability fix rather than a bug fix:
setting the queue name in `.env` now does something instead of nothing. Both
are documented in `.env.example`, which never mentioned them.

#### `get_outputs` and a NULL `outputs` column — premise does not hold

The reported crash is `json.loads(row["outputs"]) or []` raising `TypeError`
when the column is NULL, because the parse happens before the `or` can apply.
The Python is exactly as described — `json.loads(None)` does raise, and the
old psycopg code's `row["outputs"] or []` did not have the problem because
psycopg deserialized jsonb for you. But the column cannot be NULL:

```
$ grep outputs packages/api/api/core/schema.py
  outputs jsonb NOT NULL DEFAULT '[]'::jsonb,
```

`compute.jobs.outputs` is `NOT NULL DEFAULT '[]'`, so `json.loads` never sees
`None`, and a test that tries to set up the state fails on the constraint:

```
asyncpg.exceptions.NotNullViolationError: null value in column "outputs"
of relation "jobs" violates not-null constraint
```

The guard is in anyway — it is two lines, this query bypasses `_decode` and
reads the column as text, and if the constraint is ever relaxed the failure
mode is a 500 rather than an empty list. But it is defensive, not a fix for a
reachable bug, and the code comment says so rather than implying otherwise. I
did not add a test for a state the schema forbids.

#### No Procrastinate-to-rqueue data migration path — confirmed not blocking

Asked to look for evidence of a live deployment before deciding how loud to
make this. There is none, and the maintainer confirms the repository has not
been deployed:

- `.github/workflows/release.yml` builds, attests, compose-smokes and promotes
  images to `ghcr.io`, publishes to PyPI and cuts a GitHub release. It has no
  deploy job and no environment other than `pypi`. Nothing consumes the
  promoted images.
- No deployment infrastructure of any kind in the tree: no Terraform, Ansible,
  Kubernetes manifests, systemd units, `Procfile`, `fly.toml`, or deploy
  script; no host, registry or database outside `localhost`/compose service
  names anywhere in the repo.
- `DEPLOY.md`, which `readme.md`, `packages/api/readme.md` and
  `ARCHITECTURE.md` all link to, does not exist — there is no deployment
  runbook to add a drain step to.
- Three tags (`v0.0.1`, `v0.1.0`, `v0.1.1`), all `v0.x`, all July 2026.

So there is no `procrastinate_*` schema anywhere holding real rows, and no
cutover to sequence. Left as the stage-2/3 follow-up it has been called twice.
The maintainer's point stands and is worth recording: **this is exactly why
the architecture wants to be right before first deploy** — the same schema move
is cheap now and expensive once there is data behind it. That argues for
settling the `queue_migrate.py` question (below) in stage 2 rather than later,
not for building a live migration now.

### Second pass

Gate A passed. Gate B raised seven; six were real.

#### Untranslated connection errors mid-statement — real, and worse than reported

Fixed; see "Transient classification: `acquire()` was the wrong seam". Worth
repeating that the likeliest form of this failure (`InterfaceError`) was not in
`_CONNECTION_ERRORS` at all, so widening the placement alone would not have been
enough, and that the first version of my own fix was wrong in a way the
integration test caught.

#### `complete_job` outside the failure-recording path — real

Fixed; see "Finalization is part of the run, not after it", including the
partial-failure table and the guard that stops a half-succeeded `complete_job`
from being reported as a failure.

#### A redelivered completed job re-runs — real

Fixed; see "At-least-once means a completed job can come back".

#### The reconciliation uuid cast can abort the whole pass — real

Reproduced exactly as reported:

```
tsdhn=# SELECT ('{"compute_job_id":"not-a-uuid"}'::jsonb->>'compute_job_id')::uuid;
ERROR:  invalid input syntax for type uuid: "not-a-uuid"
```

One malformed row would abort the statement, silently un-reconciling every other
stuck job. The obvious guard — a regex predicate in the same `WHERE` as the cast
— does *not* work, because PostgreSQL may evaluate the two qualifiers in either
order. The cast now lives in the select list of a `MATERIALIZED` CTE, behind the
regex in that CTE's own `WHERE`: a projection is computed only for rows that
passed the filter, and `MATERIALIZED` stops the planner folding the levels back
together. A payload this codebase did not write is skipped, not fatal.

Tested with a real malformed row sitting beside a genuinely stuck job. With the
regex predicate removed the test fails with the exact production error
(`InvalidTextRepresentationError: invalid input syntax for type uuid:
"not-a-uuid"`); with it, the stuck job is reconciled and the bad row ignored.

#### Zombie kernel threads racing a newer attempt — real; bounded in pass two, fenced in pass three

Pass two closed this as far as the brief allowed (a between-steps flag) and
disclosed the residual. Pass three sharpened the residual into something that
had to be fixed rather than documented, and lifted the DDL restriction to allow
it. See "Abandoned kernel threads: fenced in the database".

#### Hardcoded queue name — real, trivial

`compute_stack_smoke.sh` and `test_repository_integration.py` now read
`COMPUTE_QUEUE` (`: "${COMPUTE_QUEUE:=simulations}"` in the script,
`api.core.settings.COMPUTE_QUEUE` in the test). `test_tasks.py`'s
`RecordingQueue` fixture was given the same treatment for consistency. The
remaining literal `simulations/` strings in the smoke script are MinIO object
key prefixes from `complete_job`, unrelated to the queue name, and are left
alone.

#### No Procrastinate-to-rqueue data migration path — raised again, unchanged

Gate B raised this again without engaging with last round's investigation. I
re-checked; nothing in this round's changes touches it, and the evidence is
identical:

- `.github/workflows/` — six workflows, and `environment: pypi` in
  `release.yml` is still the only GitHub environment in any of them. No deploy
  job.
- No Terraform, Ansible, Kubernetes manifests, systemd units, `Procfile`,
  `fly.toml` or Helm chart anywhere in the tree.
- `DEPLOY.md` still does not exist.
- Three `v0.x` tags, all July 2026.

The maintainer confirms directly that the repository has not been deployed. So
there is no `procrastinate_*` schema holding real rows and no cutover to
sequence, and building a migration path would be work for a deployment that does
not exist. It stays a stage-2/3 follow-up. The maintainer's framing is the right
one and is worth keeping in front of whoever does stage 2: **the architecture
should be settled before first deploy, precisely because this migration is cheap
now and expensive later.**

---

### Third pass

#### The abandoned-attempt residual can undo reconciliation — real, and the reason the DDL restriction was lifted

The finding this round is the same race as pass two's, stated at the point where
it actually costs something: a stale write can flip a reconciled `failed` job
back to `running`, so reconciliation's guarantee does not hold under the
condition that creates it. Fixed with `compute.jobs.owner_attempt` and a
same-statement fence on every write in an attempt's lifetime; see the design
section. Two integration tests reproduce it — one drives the exact scenario
(crash, lease expiry, reconciliation, then a stale write from the still-running
attempt) and one covers the superseded-attempt case — and both fail if either
predicate is removed.

#### The SIGTERM comment overstated graceful shutdown — real

`worker.py` claimed `stop()` "lets in-flight simulations finish". rqueue's
`shutdown_timeout` is 30 seconds and a simulation runs for tens of minutes, so
that is not what happens. The comment now describes the real behaviour, which is
the *correct* behaviour and is what the SIGTERM by-hand check already observed:
a bounded grace period, then the lease is handed straight back as `pending`
rather than left to expire, and the next worker resumes from the work
directory's checkpoints. Widening the timeout to cover a 30-minute run would be
a different and much larger decision, and is not made here.

#### The documented `rqueue migrate` command did not work — real

Two problems in `packages/api/readme.md`: `--database-url "$COMPUTE_DATABASE_URL"`
expands to empty on a fresh clone (rqueue's CLI reads `RQUEUE_DATABASE_URL`, and
`COMPUTE_DATABASE_URL`'s default lives in `settings.py`, which the shell cannot
see), and `--schema task_queue` was hardcoded. The command now uses the same
`${VAR:-default}` shape `mise.toml`'s `db:migrate` task already used, with the
defaults `settings.py` uses, and the readme says why the URL is passed
explicitly.

Verified by running it the way the finding describes — a clean environment,
`.env.example` sourced, nothing else exported:

```
$ env -u COMPUTE_DATABASE_URL -u COMPUTE_QUEUE_SCHEMA -u RQUEUE_DATABASE_URL bash -c '
    set -a; . ./.env.example; APP_DB_PASSWORD=...; set +a
    uv run tsdhn-compute-migrate && uv run rqueue --database-url "..." --schema "..." migrate'
INFO - compute schema applied; role tsdhn_app provisioned
compute-migrate exit: 0
applied 0001_core / 0002_scheduling / 0003_queue_pause
rqueue migrate exit: 0
```

Also checked that a non-default schema is honoured (`COMPUTE_QUEUE_SCHEMA=picv_queue`
creates `picv_queue`, not `task_queue`). Both schemas and the `tsdhn_app` role
were dropped from the shared local cluster afterwards.

#### The e2e scripts invented a variable name — real

Both scripts used `QUEUE_SCHEMA`, which exists nowhere else in the stack;
`docker-compose.yml`, `mise.toml`, `.env.example`, `settings.py` and the readme
all use `COMPUTE_QUEUE_SCHEMA`. Renamed in both (3 references in
`compute_stack_smoke.sh`, 4 in `crash_recovery_e2e.sh`), so exporting the real
variable now reaches them.

---

### Fourth pass

#### `AbandonedAttempt` reached rqueue as a task failure — real, and my docstring said otherwise

`AbandonedAttempt` has two origins, and I had only reasoned about one. On the
**cancellation** path the coroutine is already gone, so nothing propagates it —
which is what the class docstring claimed, flatly, for both. On the
**refused-write** path the coroutine is still live and awaiting
`asyncio.to_thread(run_simulation, ...)`, so the exception arrives in
`run_simulation_task` as an ordinary exception, falls into `except Exception`,
and reaches rqueue as a genuine failure: `_fail_terminal`, a
`rqueue.job.failed` counter, rqueue's own warning, and `_record_failure`'s
`logger.exception`. No data was ever at risk — the write was fenced to zero
rows, which is the whole point — but an on-call engineer reading failure
metrics could no longer separate a simulation that broke from the fence working
correctly. A safety mechanism that reports itself as a fault is a bad safety
mechanism.

Fixed by catching `AbandonedAttempt` explicitly and re-raising it as
`rqueue.CancelJob`, rather than by returning quietly. `CancelJob` was the right
choice over a bare `return` for a reason worth recording:

- rqueue handles `CancelJob` *before* the generic exception branch, so it
  records no failure metric and logs no exception. It counts
  `rqueue.job.cancelled`, which is an honest description of a stand-down.
- Reaching this point means a newer attempt owns the row or the job is already
  terminal, both of which imply the lease is gone — so in practice
  finalization hits `LeaseLost` and rqueue logs "could not finalize a job it no
  longer leases", which is exactly what happened.
- If the lease somehow *did* survive, a bare `return` would have rqueue mark
  the job **succeeded** while `compute.jobs` was never completed — a stuck job
  reconciliation would not catch, because it only looks at `failed` and
  `cancelled`. `CancelJob` makes the queue row `cancelled`, which reconciliation
  does repair. The safer branch is also the honest one.

Both docstrings now describe the two paths and their different consequences.
`test_a_stand_down_is_not_counted_as_a_failed_job` drives a real worker whose
kernel is superseded mid-run and asserts the queue row is `cancelled`, not
`failed`, and that reconciliation then repairs `compute.jobs`. Without the fix
it fails with `assert 'failed' == 'cancelled'`.

The same treatment now covers `complete_job` returning `False`: that attempt
raises `CancelJob` too, which additionally stops it from `rmtree`-ing a work
directory the attempt that superseded it is resuming from.

#### `queue.py`'s docstring miscounted the rqueue imports — real

`worker.py` imports `Worker`. The docstring now names all three modules
(`queue.py`, `tasks.py`, `worker.py`) and keeps the point it was actually
making, which is about `repository.py`: it imports nothing from rqueue and
takes the queue's schema, name and `defer` callback as arguments.

#### `repository.fail_job` is dead — real, deleted

It was `_fail_exhausted`'s writer, and reconciliation replaced it with a
set-based statement. Nothing but its own tests called it, so it is gone. The
test that exercised it directly is gone with it; the one that used it to reach
a failed state now gets there through `mark_started` + `record_failure`, which
is how production reaches that state — a better test than it was before.

#### `complete_job` ignored its update count — real

The terminal-status half of this finding I disagree with (below), but this half
is right independent of that. `complete_job` uploaded to MinIO, ran
`conn.execute(...)`, and never looked at whether the `UPDATE` matched. A
superseded attempt reaching that point wrote nothing, said nothing, and left
objects in object storage with no row pointing at them. It now uses `RETURNING`
like `mark_started` and `record_progress`, returns a bool, and logs at ERROR
with the bucket and key when the write did not land, so the orphan is traceable.

#### `mark_started` refusing only `COMPLETED` — correct as built; pushing back

The finding says `mark_started` should refuse `FAILED` as well as `COMPLETED`.
It should not, and the reason is a real rqueue feature. `Admin.retry_job` ->
`Storage.retry_terminal` is documented as "the only path from a terminal state
back to pending", and this is its statement:

```sql
UPDATE {jobs} SET state = 'pending',
    max_attempts = LEAST(1000, GREATEST(j.max_attempts, j.attempt + $3::int)),
    ... finished_at = NULL, lease_token = NULL, error_type = NULL ...
WHERE j.id = $1 AND j.state IN (terminal)
```

So an operator retry is not a special delivery path: it puts the *same* row
back to `pending` with a raised budget, a normal worker claims it, `attempt`
increments, and `run_simulation_task` runs with the same handler and the same
`mark_started` call. Meanwhile `compute.jobs.status` is `failed` — that is the
whole reason the operator is retrying — and `owner_attempt` holds the number of
the attempt that failed.

If `mark_started` refused a `failed` row, that retry would claim the job, run a
full simulation, and have every single write rejected by the fence, ending back
at `failed` with nothing to show for the compute. The reported bug is smaller
than the bug the fix would introduce.

Verified rather than reasoned:
`test_an_operator_retry_of_a_failed_job_can_still_start` fails a job for real,
calls `rqueue.Admin(...).retry_job(...)` through its public API, drains a
worker, and asserts the job reaches `succeeded` / `completed`. The
`owner_attempt IS NULL OR owner_attempt <= $n` predicate is what lets that
happen: attempt 4 supersedes attempt 3, which is the intended direction.

#### `complete_job` without a terminal-status guard — correct as designed

I agree with leaving it out, and the reasoning is a tradeoff worth stating
rather than an oversight. `complete_job` is already fenced on `owner_attempt`,
so a *superseded* attempt cannot write through it. The only thing a terminal
guard would additionally refuse is a genuine, finished result landing on a row
that reconciliation had already marked `failed`.

Reconciliation is a heuristic: it fires when the queue gave up, which is not
proof the work did. Refusing a result that a simulation actually computed —
tens of minutes of CPU, outputs already durable in MinIO — because a reconciler
guessed first is the wrong trade for a compute pipeline. The result is real; the
reconciler's `failed` was an inference. Letting the real outcome win is right,
and the outcome is now visible either way, because the row-count check above
logs whenever the write does not land.

#### rqueue's executor blocks shutdown — real, not this repo's to fix

Confirmed independently against `rqueue.executor.bounded_default_executor`,
whose `finally` ends with `executor.shutdown(wait=True)`:

```
coroutine cancelled at 0.10s
context manager exit returned at 3.00s      # a 3s blocking to_thread
```

So `Worker.run()` does not return on shutdown until in-flight
`asyncio.to_thread` work finishes by itself, even though `_shutdown_inflight()`
has already handed the lease back correctly within `shutdown_timeout`. This is
an rqueue defect and is filed there; it is deliberately **not** worked around in
`worker.py`, which would mean application-level complexity papering over a
library bug.

Operationally today: the lease is handed back on time, so another worker can
take the job immediately — what lags is the old process exiting. What actually
bounds the window in which two workers could touch the same work directory is
the orchestrator's own SIGKILL after its grace period (Docker's default is a few
seconds after SIGTERM), not rqueue's shutdown sequence. The `worker.py` comment
now says exactly this rather than implying a clean exit.

#### Procrastinate data migration, fourth time

Raised again, unchanged. Not re-investigated — see follow-up 2, which records
the evidence and that it has now been checked in three rounds with the same
result and confirmed directly by the maintainer.

---

### Fifth pass

#### `TooManyConnectionsError` was classified permanent — real, and the basis was wrong, not just incomplete

Verified: `TooManyConnectionsError` is `InsufficientResourcesError` (SQLSTATE
53300), not `PostgresConnectionError` (class 08), so pool exhaustion — a
textbook transient condition — failed jobs outright.

I did not add the one type. The tuple of exception classes was the wrong basis:
it *looked* exhaustive, was not, and grows by one entry per incident. It is
replaced by classification on the SQLSTATE class, with four classes allowed:

```
08  connection_exception     the connection broke or was refused
53  insufficient_resources   too many connections, out of memory, disk full
57  operator_intervention    admin shutdown, crash shutdown, cannot connect now
40  transaction_rollback     serialization failure, deadlock detected
```

**Why a wide net is right here, defended rather than assumed.** The two errors
are not symmetric. Calling a transient failure permanent throws away a
simulation that would have succeeded — tens of minutes of compute, plus an
operator retry to recover it. Calling a permanent failure transient costs two
extra attempts and about 45 seconds of backoff before it fails anyway with the
same error. So carrying the few genuinely permanent members inside these classes
(57P04 `database_dropped`, say) is a good trade for catching every transient one.

The net is bounded on purpose, and the boundary follows the same logic. Classes
22 (data exception), 23 (integrity constraint) and 42 (syntax and access rules)
stay permanent: those are application bugs, and a retry there re-runs an entire
simulation to arrive at the identical failure. Client-side `ConnectionError`,
`OSError` and `TimeoutError` remain transient as before, and the
`InterfaceError`-only-if-the-connection-is-gone rule from the second round is
unchanged.

`test_transient_classification_follows_the_sqlstate_class` pins thirteen cases
across both sides of that line, and a second test drives pool exhaustion through
`db.acquire()`. The error message became "database unavailable", since
"connection failed" was no longer accurate for a deadlock or an out-of-memory.

#### The COMPLETED guard was check-then-write — real, and my own fence's rule caught me

`run_simulation_task` read `row["status"]` from a `fetch_by_id` SELECT and
branched on it before calling `mark_started`. That is exactly the shape the
`owner_attempt` fence exists to eliminate, and I left it in the one place the
fence was introduced. An attempt completing between the SELECT and the UPDATE
could still have `completed` overwritten with `running`.

The predicate is now inside `mark_started`'s statement, alongside the
`owner_attempt` one, and the claim's return value is the decision. The up-front
read stays — it supplies `input_params` and `simulation_id` — but decides
nothing. `_stand_down` re-reads afterwards only to choose between "already
completed, let this delivery succeed and clean up" and "superseded, raise
`CancelJob`"; a stale read there is harmless because the authoritative answer
was the UPDATE.

`completed` is refused; `failed` still is not, for the operator-retry reason
established last round and covered by its own test.

#### Stale `error` / `finished_at` on a reclaimed row — worth clearing, not cosmetic

The finding called this a cosmetic window. It is not, and `mark_started` now
clears both. `status_from_row` hands `status`, `error` and `finished_at` to the
status endpoint and to SSE *together*, so a row that reads `running` while
carrying a previous attempt's error text and a finish time in the past is not a
state any client can render correctly — there is nothing in the payload that
distinguishes a stale error from a live one. The operator-retry path makes this
reachable in normal operation, not just after a crash. One line in the UPDATE,
with a test.

#### The readme's migrate block needed `APP_DB_PASSWORD` — real

`tsdhn-compute-migrate` provisions the web role and refuses to invent a
password, which is correct, but the readme did not say so. The block now
exports one first, and explains why there is no default. Verified by running it
exactly as written in a scrubbed environment (`env -i`, `.env.example` sourced,
nothing else):

```
INFO - compute schema applied; role tsdhn_app provisioned
compute-migrate exit: 0
applied 0001_core / 0002_scheduling / 0003_queue_pause
rqueue migrate exit: 0
```

Confirmed the migration creates `compute.jobs.owner_attempt` on a fresh
database; the schemas and the role were dropped from the shared local cluster
afterwards.

#### The workspace race — fixed, not disclosed

I landed a real fix rather than taking the offered residual. See "The workspace
is fenced separately, with `flock`" for the mechanism, why a plain marker file
cannot work, and the two residuals that remain (a thread that never reaches
another progress callback, and multi-host network volumes) — both bounded,
visible, and documented in the module docstring.

#### Already settled, repeat count only

- **Procrastinate data migration.** Fifth round, including this round's variant
  ("a resubmission with the same `simulation_id` on a stranded old row returns
  the stranded row"). Same root cause, same settled answer: there is no live
  deployment for anything to be stranded in. Not re-investigated; see follow-up
  2.
- **rqueue's executor blocks shutdown.** Second round. Reproduced and filed
  against rqueue last round; not this task's to fix. See follow-up 8b.

---

### Sixth pass

Both real findings this round were introduced by the `flock` fix itself, which
is a fair outcome for a change that added a second locking domain: the review
caught the two places where the new lock's *scope* and *lifetime* were wrong.
Neither existed before the fifth round.

#### The upload ran outside the lock — real

`own_workspace`'s `with` block closed inside the kernel-thread wrapper, before
`complete_job` read the result files back out of the same workspace to upload
them. A lease lost in that window let a redelivered attempt win `mark_started`
(the row still reads `running`, not yet `completed`), take the freed lock, and
start writing into the directory the previous attempt was still uploading from.
The same corruption class the lock exists to prevent, moved a few lines later.

The fix is not "move the lock into the coroutine" — that reintroduces what the
fifth round fixed, because a coroutine-scoped `finally` releases at cancellation
while the kernel thread writes on. Both holders are uncancellable, and they can
*end in either order*, so no single owner is correct:

| Released by | Kernel still running after a cancel | Upload after the kernel returns |
| --- | --- | --- |
| the coroutine | **unprotected** | protected |
| the kernel thread | protected | **unprotected** |
| whichever finishes last | protected | protected |

`WorkspaceClaim` is that third row: one `flock`, two shares, closed by whichever
holder gives its share back second. The kernel thread releases in a `finally` on
the thread; the coroutine releases in a `finally` after `complete_job`.

Verified by negative check — building the claim with a single share makes two of
the new tests fail with `DID NOT RAISE TransientInfraError`.

Residual, stated rather than implied: a cancellation *during* the upload
releases the coroutine's share while anyio's upload thread may still be reading.
That thread only reads, and a replacement writing underneath it makes the upload
fail into a retry rather than corrupt anything, so it is a degradation, not the
corruption class above.

#### `remove_workspace` unlinked a lock it did not hold — real

The classic `flock` + `unlink` trap, and reachable: `sweep_abandoned_work_dirs`
runs against jobs whose row is terminal while their kernel thread is still
alive. Reproduced directly:

```
zombie holds the lock
sweep unlinked the lock file (zombie still holds its inode)
!! a new attempt ALSO acquired the lock -- two exclusive owners
same inode? False
```

`unlink` drops the directory entry; the holder keeps its lock on the orphaned
inode, which nothing looks up by path any more, so the next `O_CREAT` creates a
*new* inode and locks it uncontended. The lock silently stops meaning anything
at exactly the moment it matters most.

`remove_workspace` now takes the lock itself, non-blocking, before removing
anything, and returns whether it succeeded. A refusal is not an error — the
directory stays where its owner expects it and the next sweep retries. The
success path in `run_simulation_task` gives its claim back *before* calling it,
so removal re-takes the lock rather than deleting one it is holding. Negative
check: restoring the old unlink-first body makes the new test fail with
`assert True is False`.

#### Already settled, no action

- **`complete_job` overwriting a reconciled `failed` row.** Same finding, same
  answer: a real result outranks a reconciler's inference, and `Admin.retry_job`
  depends on `FAILED` being reclaimable. Closing the upload-scope hole above
  makes this more clearly right, not less — it removes the one way the "genuine
  result" could have been corrupted in flight.
- **Procrastinate data migration.** Sixth round. See follow-up 2.

#### Judgement call, left as documented

A SIGTERM leaves the claim held until the kernel thread exits on its own, so a
40-50s step could in principle consume a retry. Left as the disclosed trade in
the workspace section — a visible, bounded failure over silent corruption — and
bounded in practice by the orchestrator's own SIGKILL grace period. Widening the
claim to cover the upload does not change that reasoning: it extends the window
slightly while removing a corruption path, which is the same trade already made.

---

### Seventh pass

Done as a separate, stacked task (`picv-workspace-claim-leak`, codex) rather
than a further round on this one, to keep spending the same session's context
budget on a fresh reviewer instead of an increasingly-loaded one. Both findings
were introduced by the `WorkspaceClaim` fix in the sixth pass — a lost race
during the claim handoff, and a gap in what the cleanup sweep covers.

#### A lost race during `claim_workspace` could leak the fd and its `flock` forever — real

`asyncio.to_thread(claim_workspace, ...)`'s underlying thread cannot be
stopped once started. If the coroutine awaiting it was cancelled after the
thread had already acquired the `flock` and built a `WorkspaceClaim`, but
before `held, resume = await ...` assigned the result, the `CancelledError`
propagated with `claim` still `None`. The `finally: claim.release()` at the
bottom of `run_simulation_task` never saw that claim, so the fd — and the
`flock` held against it — stayed open for the life of the worker process. No
later attempt could ever claim that workspace again.

A second, narrower leak sat inside `claim_workspace` itself: an `OSError` from
`os.ftruncate`/`os.write` *after* `fcntl.flock` had already succeeded was not
caught, so the fd was never closed on that path either.

Fixed by giving `claim_workspace` sole responsibility for the fd once it is
open — any failure after that point, flock included, closes it before
propagating. The lost-race half is fixed by `_claim_workspace_safely`:
`asyncio.shield` keeps cancellation of the waiter from cancelling the
underlying claim task, and if the shield still raises `CancelledError` into
the caller (the shield protects the task, not the waiter), a detached "drain"
task takes ownership of the claim once the thread actually finishes and
releases both its shares. A module-level set holds a reference to the drain
task so it is not garbage-collected mid-flight.

#### A completed job's workspace could leak permanently if cleanup lost the race — real

`remove_workspace` (already correct about the `flock`+`unlink` order from the
sixth pass) returns whether it actually removed anything. Both call sites that
matter — the success path in `run_simulation_task`, and the
already-completed-redelivery path in `_stand_down` — ignored that return
value. `sweep_abandoned_work_dirs`, the only other caller, only ever looked at
`failed` jobs. A `completed` job whose removal lost the lock race (a zombie
thread from an earlier attempt still holding it) had no path back to cleanup
at all.

Fixed by widening what the sweep considers: `list_abandoned_work_dirs` now
returns `failed` or `completed` jobs past `WORK_DIR_TTL`, so a completed job's
workspace that failed to remove synchronously gets retried on the next sweep
pass, the same way a failed job's already did.

#### Verified

`mypy --strict`, `ruff check`, 276 passed / 14 skipped fast (+3 over the sixth
pass), 42 passed integration. New tests cover a post-flock descriptor failure,
cancellation during the claim handoff, a completed workspace's removal being
retried after an initial refusal, and the sweep query now including
`completed`.

---

---

## A second problem found, for its own task

**`packages/api/readme.md` and `ARCHITECTURE.md` both link to `DEPLOY.md`,
which does not exist in the repository.** Pre-existing on `bump`, unrelated to
this change, and left alone.

---

## Follow-ups

1. **The `rqueue` dependency is a git commit pin, not a released-version
   pin.** No longer a build blocker (the image builds; see above) and no longer
   machine-specific, but upgrading rqueue means editing a commit hash by hand,
   and every install clones a GitHub repository rather than fetching from an
   index. Should become a normal version specifier once rqueue publishes a
   release.
2. **Stage 2's migration story.** `docker-compose.yml` now runs rqueue's
   migrate, but nothing handles an already-deployed `procrastinate_*` schema in
   `compute` or its in-flight rows.

   **A review gate has raised this in all six rounds. It was investigated
   twice, confirmed twice with the same evidence, and the maintainer has
   confirmed it directly: picv-2025 has never been deployed.** Rounds three
   through six were not re-investigated, by agreement and because nothing in any
   of them touches the question. The fifth round's variant ("a resubmission
   with the same `simulation_id` on a stranded old row returns the stranded
   row") is the same root cause with the same answer: nothing can be stranded
   in a deployment that does not exist. No deploy job in
   any of the six workflows (`environment: pypi` in `release.yml` is the only
   GitHub environment); no Terraform, Ansible, Kubernetes manifests, systemd
   units, `Procfile`, `fly.toml` or Helm chart anywhere in the tree; no host,
   registry or database outside `localhost` and compose service names;
   `DEPLOY.md` does not exist, so there is no runbook to add a drain step to;
   three `v0.x` tags, all July 2026. There is therefore no `procrastinate_*`
   schema anywhere holding real rows, and no cutover to sequence. This is
   recorded so a future reader knows it was checked rather than overlooked, and
   does not spend a fourth round on it. It stays a genuine stage-2/3 item —
   whoever ships the first deployment needs a story for it — but it is not a
   defect in this change and it is not blocking.
3. **Role grants for `task_queue`.** The web role is correctly locked out
   (tested), but rqueue's own least-privilege producer/worker roles
   (`rqueue grant-role`) are not provisioned; the app connects as the owner.
4. **The two compose e2e scripts were ported but not run.** The image now
   builds, so this is no longer blocked — they were not run because they need
   the full compose stack plus the real scientific toolchain end to end, which
   is a much longer exercise than this task's verification budget.
   `compute_stack_smoke.sh` now
   asserts against `task_queue.jobs`, and `crash_recovery_e2e.sh`'s scenario 1
   now watches `attempt` on rqueue's row instead of Procrastinate's; the
   scenario is a better fit than before, since rqueue's fenced lease recovery
   is what reclaims the job rather than a reaper task.
5. **Project-local PostgreSQL port collides with rqueue's** (see above).
6. ~~**`repository.fail_job` is now production-dead.**~~ **Done** — deleted in
   the fourth review round, along with the test that exercised it directly. The
   test that used it to reach a failed state now gets there through
   `mark_started` + `record_failure`, the way production does.
7. **`crash_recovery_e2e.sh` has no exhausted-budget scenario.** Its scenario 1
   crashes a worker *with* attempts remaining, so it never reaches the state
   reconciliation exists for. That state is covered by the integration test,
   which runs; a compose scenario would be better still, but adding one I
   cannot run here (see follow-up 4) would be untested script.
8b. **rqueue: `bounded_default_executor` blocks worker shutdown.** Its `finally`
   calls `executor.shutdown(wait=True)`, so `Worker.run()` does not return until
   in-flight `asyncio.to_thread` work finishes on its own -- reproduced at a
   cancelled-at-0.10s coroutine whose context-manager exit returned at 3.00s.
   The lease is still handed back on time, so this delays the process exiting
   rather than the job moving; today the orchestrator's SIGKILL bounds it.
   **Filed against rqueue, not worked around here.**
8. ~~**Fence progress writes on the owning attempt.**~~ **Done** — the DDL
   restriction was lifted for it in the third review round. `compute.jobs`
   gained `owner_attempt`, and every write in an attempt's lifetime is now
   fenced in the same statement as the write. Kept here only so the follow-up
   numbering in earlier rounds still resolves.
