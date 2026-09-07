# picv-2025: rqueue's roles and admin surfaces (stage 2)

Branch `cap/picv-rqueue-operability`, off `bump` at `90aef46`, stacked on
stage 1 (`cap/picv-asyncpg-rqueue-v2`). Changes left uncommitted.

**How the base got here.** The worktree captain gave me was clean at `90aef46`
with none of stage 1's work in it, so I applied stage 1's uncommitted diff
(plus its two untracked files, `api/core/queue.py` and
`tests/test_worker_integration.py`) from `~/.cap-work/picv-asyncpg-rqueue-v2`
first, and verified the two trees were identical before starting. Everything
below is additive on top of that; `git status` therefore shows both stages'
changes uncommitted together. My own diff touches exactly these files:

| File | What happened |
| --- | --- |
| `api/queue_grants.py` | **New.** Provisions the three runtime roles; `tsdhn-queue-grants` entry point. |
| `api/core/settings.py` | Three role/password pairs, plus `role_database_url()`. |
| `api/core/db.py` | `open_pool(..., dsn=)`, `runtime_dsn()`, and `connect()` reusing the pool's DSN. |
| `api/main.py` | The API's pool opens as the producer role. |
| `api/worker.py` | The worker's pool opens as the worker role; `purge_pool()`; the purge task beside the sweep. |
| `api/core/tasks.py` | `JOB_RETENTION`, `purge_finished_jobs`, `run_periodic_purge`, and `_run_periodically` shared with the sweep. |
| `docker-compose.yml`, `mise.toml`, `scripts/integration.sh`, `.env.example`, two workflows | Run `tsdhn-queue-grants`, and carry the three passwords. |
| `scripts/database.py` | `--role` repeatable; `drop_role` tolerates a role that was never created. |
| `readme.md`, `packages/api/readme.md`, `ARCHITECTURE.md` | The grant table and the retention window. |
| `tests/test_queue_roles_integration.py` | **New**, 15 tests against real roles on real PostgreSQL. |
| `tests/test_db.py`, `tests/test_tasks.py` | 6 new database-free tests. |

No new dependencies; `uv.lock` is untouched.

---

## Part 1: least-privilege roles for `task_queue`

### Where provisioning lives, and why it is a new script

**A new module and entry point, `api/queue_grants.py` / `tsdhn-queue-grants`,
not an extension of `migrate.py`.** The brief invited me to consider
`migrate.py`, and the deciding fact is ordering, not taste: rqueue's role
grants name tables in `task_queue`, and `docker-compose.yml` runs
`tsdhn-compute-migrate` **before** `rqueue ... migrate`. A grant issued from
`migrate.py` would fire against a schema that does not exist yet.

That is the same constraint that already produced `web_grants.py`: create the
role in `migrate.py`, grant its tables in a second step after the migrations
that create them. So this mirrors an existing shape rather than inventing one.
Two smaller reasons point the same way: `provision_role` is asyncpg and
`migrate.py` is psycopg, and role provisioning for the queue is a thing you
want to re-run on its own when a grant drifts.

It runs last in all four places that apply migrations — `docker-compose.yml`'s
`compute-migrate`, `mise run db:migrate`, `scripts/integration.sh`, and the
readme's by-hand sequence.

### The three roles

`COMPUTE_DATABASE_URL` stays what it was: the schema owner, used for
migrations and grants only. The runtime connects as these instead.

| Setting | Default | Process | Capability | Extra |
| --- | --- | --- | --- | --- |
| `COMPUTE_PRODUCER_ROLE` | `tsdhn_producer` | API | `PRODUCE` | `SELECT, INSERT` on `compute.jobs` |
| `COMPUTE_WORKER_ROLE` | `tsdhn_worker` | worker | `CONSUME` | `SELECT, UPDATE` on `compute.jobs` |
| `COMPUTE_PURGER_ROLE` | `tsdhn_purger` | worker retention | `INSPECT` | `DELETE` on `task_queue.jobs`; nothing in `compute` |

All three are scoped with `queues=(COMPUTE_QUEUE,)` — the literal
`simulations`, not `("*",)`. picv-2025 has exactly one queue and I found no
sign of a second; widening it later is an `INSERT` into
`task_queue.role_queue_grants`, not a code change, which is the point of
rqueue putting the scope in a table.

**The API gets `PRODUCE` and not `PRODUCE + INSPECT`.** The brief asked me to
check what `/health` actually touches before assuming. It touches nothing in
the queue: `repository.is_database_connected()` is `SELECT 1` on a pooled
connection (`repository.py:231`). No route reads `task_queue` at all today.
What `INSPECT` would add over `PRODUCE` is `SELECT` on `schedules`,
`schedule_occurrences` and `queue_pauses`; `PRODUCE` already carries `SELECT`
on `jobs` and `job_attempts`, which is what an admin surface showing job state
would want. picv-2025 runs no scheduler and never pauses a queue, so the extra
three tables would be grants for a surface that does not exist.

**Compute-schema grants are mine, not rqueue's.** `provision_role` only knows
about the queue schema, and both processes share one pool across
`compute.jobs` and `task_queue.jobs`. So `queue_grants.py` adds the
`compute.jobs` privileges each process actually uses, revoke-first so a
re-run repairs drift, exactly as `migrate.provision_web_role` does for the web
role. The split is asymmetric on purpose and it is real: the API inserts and
reads (`create_or_get_job`) and never updates; the worker updates and reads
(`mark_started`, `record_progress`, `record_failure`, `complete_job`) and
never inserts.

### Connecting as them

`settings.role_database_url(role, password)` rewrites `COMPUTE_DATABASE_URL`'s
credentials — the same shape `docker-compose.yml` already uses to build the
web role's DSN out of `APP_DB_ROLE` and `APP_DB_PASSWORD`, one URL for where
the database is with credentials layered on. `db.open_pool` takes that DSN and
remembers it, so `db.connect()` — the dedicated connection the SSE stream
holds outside the pool — reaches the database as the same role rather than
quietly falling back to the owner. That last part has its own test.

`db.runtime_dsn()` returns `None` when the password is unset, and logs a
warning naming the role. The asymmetry is deliberate and mirrors
`APP_DB_PASSWORD`: **provisioning refuses to run without a password, the
runtime warns and keeps working.** A deployment that has not yet run
`tsdhn-queue-grants` still starts, loudly, rather than failing to boot on a
security improvement.

### What the grants actually are

Read off a real database after running the real entry point
(`information_schema.role_table_grants`, roles renamed `tsdhn_ops_*` for the
run):

```
      grantee       |            relation             |           privileges
--------------------+---------------------------------+--------------------------------
 tsdhn_ops_producer | compute.jobs                    | INSERT, SELECT
 tsdhn_ops_producer | task_queue.job_attempts         | SELECT
 tsdhn_ops_producer | task_queue.jobs                 | INSERT, SELECT
 tsdhn_ops_producer | task_queue.role_queue_grants    | SELECT
 tsdhn_ops_producer | task_queue.schema_migrations    | SELECT
 tsdhn_ops_purger   | task_queue.job_attempts         | SELECT
 tsdhn_ops_purger   | task_queue.jobs                 | DELETE, SELECT
 tsdhn_ops_purger   | task_queue.queue_pauses         | SELECT
 tsdhn_ops_purger   | task_queue.role_queue_grants    | SELECT
 tsdhn_ops_purger   | task_queue.schedule_occurrences | SELECT
 tsdhn_ops_purger   | task_queue.schedules            | SELECT
 tsdhn_ops_purger   | task_queue.schema_migrations    | SELECT
 tsdhn_ops_worker   | compute.jobs                    | SELECT, UPDATE
 tsdhn_ops_worker   | task_queue.concurrency_slots    | DELETE, INSERT, SELECT, UPDATE
 tsdhn_ops_worker   | task_queue.job_attempts         | INSERT, SELECT, UPDATE
 tsdhn_ops_worker   | task_queue.jobs                 | INSERT, SELECT, UPDATE
 tsdhn_ops_worker   | task_queue.queue_pauses         | SELECT
 tsdhn_ops_worker   | task_queue.role_queue_grants    | SELECT
 tsdhn_ops_worker   | task_queue.runtime_heartbeats   | INSERT, SELECT, UPDATE
 tsdhn_ops_worker   | task_queue.schema_migrations    | SELECT
```

Note `task_queue.jobs` shows no whole-table `UPDATE` for the producer. The
column-scoped one is there, and it is the only column privilege any of the
three holds:

```
      grantee       |    relation     | column_name | privilege_type
--------------------+-----------------+-------------+----------------
 tsdhn_ops_producer | task_queue.jobs | updated_at  | UPDATE
```

Row scope, one row per role, all naming the one queue:

```
     role_name      |    queue
--------------------+-------------
 tsdhn_ops_producer | simulations
 tsdhn_ops_purger   | simulations
 tsdhn_ops_worker   | simulations
```

---

## Part 2: retention for `task_queue.jobs`

### Where it runs

A sibling task beside the work-dir sweep, on the same `asyncio.Event`. Both
now go through one `tasks._run_periodically(action, stop, interval,
description)` that keeps the existing behaviour verbatim — run, log an
exception and carry on, then wait on the event with a timeout — so a failing
purge cannot take the worker down and cannot stop the sweep either. The public
names `sweep_abandoned_work_dirs` / `run_periodic_sweep` are unchanged and
their existing tests pass untouched. The purge interval is hourly, like the
sweep; with a week of retention the cadence is not load-bearing.

I did not reach for `rqueue.Scheduler`, for the reason stage 1 gave about the
sweep and which applies at least as well here: deleting rows that are already
past their retention window is idempotent, so two replicas racing costs
nothing and the occurrence-key machinery would be pure overhead.

### The window: 7 days

A terminal `task_queue.jobs` row has no application value at all after
`complete_job`/`record_failure`, which run inside the same handler — nothing
in the API or the worker ever reads the queue row again, and `/health` does
not touch the schema. What remains is operational: the `job_attempts` history
behind a failure, and the queue-side view of a run someone is asking about.

A week is what covers a working week plus the weekend, so a Friday-evening
failure is still inspectable on Monday morning. It is also far longer than
anything mechanical the row is involved in: the retry budget is three attempts
15s and 30s apart, and a simulation is tens of minutes. And the volume is
tiny — one row per submitted simulation — so the window is chosen for how long
a human might want to look, not to bound growth.

`compute.jobs`, which holds the results and is what the API actually reads, is
untouched and still has no retention. That stays out of scope, as the brief
says; the two windows are genuinely different questions and the queue's can be
much the shorter.

Two properties of `Admin.purge` worth stating because they are what make a
short window safe: it matches only terminal states with a `finished_at`, so a
job stuck `pending` for a month is never deleted; and it takes a `limit`
(10000 here), so a first run against a long-unpurged table cannot hold one
enormous transaction open — the next hourly pass takes the rest.

### Why a third role rather than the worker's own pool

The brief offered a purge-scoped role or running purge as the owner. I took
the third role, and the argument that decided it is narrower than "least
privilege" in general:

`CONSUME` gives the worker whole-table `UPDATE` on `jobs`, so it can already
rewrite any state, payload or attempt count in its queue. `DELETE` is not more
of the same — it is qualitatively new, because `job_attempts.job_id` cascades.
A role that can delete a job can erase that job's own attempt history, which
is the one thing a consumer currently cannot touch. Folding `DELETE` into the
worker role would make the queue's audit trail writable by the process the
trail is about.

Running purge as the owner was the alternative, and it is worse in this
design: the purge runs *inside the worker process*, so it would mean handing
that process owner credentials, undoing part 1 for the sake of part 2.

So the worker process opens a second, deliberately tiny pool (`min_size=0`,
`max_size=1`, borrowed once an hour) as `COMPUTE_PURGER_ROLE`, and `Admin` is
built on that. The practical payoff beyond the audit-trail argument is that
retention becomes separately credentialed: a deployment can withhold
`COMPUTE_PURGER_PASSWORD`, or move retention to a maintenance container, with
no code change. When it is withheld, `worker.purge_pool()` falls back to the
worker's own pool — which is the owner connection on a development database
and fails loudly, hourly, against a provisioned one.

`CONSUME`'s grant set does not cover `DELETE ON jobs`; the brief's parenthesis
is right about that. See "What contradicts the brief" for the part of the same
sentence that is not.

---

## Verification

### Static and suites

```
$ mise run lint
uv run ruff check --select E,F,W,I,B,UP,S,SIM,RUF .   -> All checks passed!
uv run ruff format --check .                          -> 96 files already formatted
uv run mypy --strict packages                         -> no issues in 94 source files

$ mise x -- uv run bandit -r packages -lll --skip B101   -> High: 0
$ mise x -- gitleaks detect --source . --no-banner       -> no leaks found

$ mise x -- uv run pytest -n auto -q -m 'not integration'
208 passed, 14 skipped        (skips are golden/parity/GMT, unrelated)

$ bash scripts/integration.sh     # full script end to end
43 passed (python)  +  2 passed (web)
```

`scripts/integration.sh` is the one that matters most: it now runs
`tsdhn-queue-grants` against a disposable database with three per-run role
names, and drops them on exit. Confirmed afterwards that the cluster held only
the `tsdhn` role again.

I did not re-run `bun run gen:client`: nothing in `routes.py` or `schemas.py`
changed, so the API surface cannot have drifted.

### New tests

`packages/api/tests/test_queue_roles_integration.py`, 15 tests, every one
connecting as a real provisioned role:

- the producer can `INSERT` and `SELECT` `jobs` and can `UPDATE ... SET
  updated_at`, but `UPDATE ... SET state = 'leased'` and `DELETE` are refused;
- the producer can read and insert `compute.jobs` but not update or delete it;
- the worker can claim (whole-row `UPDATE`) but `DELETE FROM jobs` and
  `DELETE FROM job_attempts` are both refused;
- the worker can update `compute.jobs` but not insert into it;
- the purger can `SELECT` and `DELETE` `jobs` and nothing else — `UPDATE` and
  `INSERT` refused, `compute` invisible;
- none of the three can run DDL (`CREATE TABLE`, `ALTER TABLE`,
  `CREATE SCHEMA`), parametrised over all three roles;
- a job on a second queue is invisible to all three (row-level security, not a
  grant), parametrised over all three roles;
- **the real paths, not just SQL probes**: a `Queue` on a producer-role pool
  runs `enqueue` twice with the same `dedupe_key` and
  `on_conflict="return_existing"` — the `DO UPDATE SET updated_at` path the
  column grant exists for — and a real `rqueue.Worker` on a worker-role pool
  then claims, runs and finalizes it (`succeeded`, one `job_attempts` row);
- `purge_finished_jobs` on a *worker*-role pool raises
  `InsufficientPrivilegeError` — the test that justifies the third role;
- purge on a purger-role pool removes only the job past the window, takes its
  attempt rows with it, and leaves the recent job and the never-finished job.

Six database-free tests in `test_db.py` and `test_tasks.py` cover
`role_database_url`'s credential swap and percent-encoding, the `None` result
for an unprovisioned role, `runtime_dsn`'s warning, `connect()` reusing the
pool's DSN, the purge loop surviving a failed pass, and the exact arguments
`purge_finished_jobs` passes to `Admin.purge`.

### By hand, against a real database

A disposable database `tsdhn_ops` on the local PostgreSQL 18.6 cluster, both
schemas applied by their real commands, the three roles provisioned by the
real `tsdhn-queue-grants`. The grant tables above are from this run.

**The privilege matrix, one statement at a time through `psql`** (`ok` = the
statement succeeded):

```
--- producer ---                     --- worker ---
SELECT jobs:            1            UPDATE state (claim):   ok
UPDATE updated_at:      ok           INSERT job_attempts:    ok
UPDATE state (claim):   permission denied for table jobs
DELETE jobs:            permission denied for table jobs
INSERT compute.jobs:    ok           UPSERT heartbeat:       ok
UPDATE compute.jobs:    permission denied for table jobs
DDL (CREATE TABLE):     permission denied for schema task_queue
DDL (ALTER jobs):       must be owner of table jobs

--- worker, continued ---            --- purger ---
DELETE jobs:            permission denied for table jobs
DELETE job_attempts:    permission denied for table job_attempts
PAUSE queue (INSERT):   permission denied for table queue_pauses
UPDATE compute.jobs:    ok           SELECT jobs:            1
INSERT compute.jobs:    permission denied for table jobs
                                     DELETE jobs:            ok
                                     UPDATE jobs:            permission denied
                                     INSERT jobs:            permission denied
                                     SELECT compute.jobs:    permission denied for schema compute
                                     DDL (CREATE TABLE):     permission denied for schema task_queue
```

**Queue scoping.** With one `simulations` job and one `other` job in the table
(both seeded as owner, who is not subject to the policy), `SELECT DISTINCT
queue FROM task_queue.jobs` returned `simulations` for all three roles.

**Purge, with cascades.** Seeded five jobs and a schedule with two
occurrences:

```
before                                 queue        state      finished  attempts  occurrences
a0000000-...-000000000001              simulations  succeeded   10 days         1            1
a0000000-...-000000000002              simulations  failed       9 days         3            0
b0000000-...-000000000003              simulations  succeeded    2 days         1            1
c0000000-...-000000000004              simulations  pending    (never)          0            0
d0000000-...-000000000005              other        succeeded   30 days         1            0
```

Ran the real `purge_finished_jobs(Admin(pool))` on a pool opened by
`db.runtime_dsn(COMPUTE_PURGER_ROLE, ...)`; `SELECT current_user` on that pool
reported `tsdhn_ops_purger`.

```
purge connects as: tsdhn_ops_purger
current_user: tsdhn_ops_purger
retention=7 days, 0:00:00 removed=2

after                                  queue        state      attempts  occurrences
b0000000-...-000000000003              simulations  succeeded         1            1
c0000000-...-000000000004              simulations  pending           0            0
d0000000-...-000000000005              other        succeeded         1            0

total job_attempts=2   total schedule_occurrences=1   schedules still present=1
```

The two jobs past the window went, and their four attempt rows and one
occurrence row went with them by cascade. The 2-day-old job stayed. The
30-day-old **pending** job stayed — retention never deletes unfinished work.
The 30-day-old job on the `other` queue stayed, both because purge filters on
the queue and because the policy hides it. The `schedules` row itself is not
touched.

**Both processes, running for real, connecting as their roles.** Started
`tsdhn-api` (port 8099) and `api/worker.py` against `tsdhn_ops`. The only
thing stubbed is `tsdhn.engine.run_simulation` — this host has no Fortran/GMT
toolchain, which stage 1 hit and documented too — replaced from a
scratch-directory driver with a stub that writes one progress step and then
raises. Everything the two processes do to the database is the production code
path under the new roles, and no MinIO is needed because the run fails.

```
$ psql -c "SELECT usename, count(*) FROM pg_stat_activity WHERE datname='tsdhn_ops' ..."
    connected_as    | count
--------------------+-------
 tsdhn_ops_producer |     1
 tsdhn_ops_purger   |     1
 tsdhn_ops_worker   |     2

$ curl .../api/v1/health
{"status":"degraded",...,"database_connected":true,"storage_connected":false}   # no MinIO here

$ POST /api/v1/jobs -> {"simulation_id":"26d9a8a9-...","status":"queued"}

task_queue.jobs:   state=failed  attempt=1  error_type=RuntimeError
compute.jobs:      status=failed  step=fault_plane  step_index=1
                   details="Pipeline failed - check error logs"
task_queue.job_attempts: attempt 1 -> failed
```

So, as the three roles and nothing else: the producer wrote `compute.jobs` and
`task_queue.jobs` in one transaction; the worker claimed the job, wrote the
progress row, recorded the failure terminally (a `RuntimeError` is not in
`retry_on`), and finalized. The purge role held its own idle connection
throughout.

**The retention pass in the live worker.** Aged that failed job's
`finished_at` to 8 days and restarted the worker:

```
2026-09-05 11:26:17,871 - api.worker - INFO - simulation worker serving queue simulations
2026-09-05 11:26:17,880 - api.core.tasks - INFO - purged 1 finished queue job(s) older than 7 days, 0:00:00

task_queue.jobs=0   job_attempts=0   compute.jobs=1
```

The queue row and its attempt row are gone; `compute.jobs` — the business
record the API serves — is untouched. That is the whole design in three lines.

**The unprovisioned path.** Started the API with `COMPUTE_PRODUCER_PASSWORD`
unset:

```
WARNING - api.core.db - no password configured for role tsdhn_ops_producer;
          connecting as the database owner instead of the least-privilege role
INFO - api.main - TSDHN API ready
```

and, in the same environment:

```
$ uv run tsdhn-queue-grants
RuntimeError: COMPUTE_PRODUCER_PASSWORD must be set: it is the password for
the database role tsdhn_ops_producer.
```

Torn down afterwards: `tsdhn_ops` dropped, all four `tsdhn_ops_*` roles
dropped, both processes stopped, work directory removed. The cluster is back
to holding only the `tsdhn` role and database.

---

## What contradicts the brief

Three things, all small, all confirmed against the code rather than reasoned
about:

1. **"the API ... reads job/queue state for `/health`."** It does not.
   `/health` calls `repository.is_database_connected()`, which is `SELECT 1`
   (`repository.py:231`), plus a threaded MinIO probe. No route in the API
   reads `task_queue` at all. This is why the producer role gets `PRODUCE`
   alone; the brief's own "check what `/health` actually touches before
   assuming" is the instruction that found it.

2. **"the worker role cannot `DELETE FROM jobs` outright (only through the
   finalize paths rqueue's own SQL uses)."** There are no such finalize paths.
   rqueue never deletes a `jobs` row when finalizing an attempt — finalizing
   is an `UPDATE` to a terminal state plus an `UPDATE` of the attempt row. The
   only `DELETE` a consumer performs anywhere is on `concurrency_slots`
   (releasing a named slot), which is why `CONSUME` carries `DELETE` there and
   nowhere else. So the worker role holds no `DELETE` on `jobs` in any form,
   which is stronger than the brief describes and is what part 2's third role
   is built around.

3. **Stage 1's report says the `rqueue` path dependency is a container-build
   blocker.** The tree I inherited does not have a path dependency:
   `packages/api/pyproject.toml` pins
   `rqueue = { git = "https://github.com/totallynotdavid/transactions.git",
   rev = "545d67aa..." }`, which is rqueue's current `HEAD` and contains
   `roles.py` and `admin.py` as this task assumes. I checked the installed
   package byte-for-byte against `~/git/transactions/src/rqueue/`. So follow-up
   1 of that report is already closed; I left it alone otherwise.

One further note that is not a contradiction but changes a deployment:
`docker-compose.yml`'s `compute-migrate`, `api` and `worker` services now
require `COMPUTE_PRODUCER_PASSWORD`, `COMPUTE_WORKER_PASSWORD` and
`COMPUTE_PURGER_PASSWORD` in `.env` (`:?set ... in .env`, matching how
`APP_DB_PASSWORD` is already handled). An existing `.env` will fail
`docker compose up` with that message until the three are added.
`.env.example`, both readmes and the two compose-driving workflows carry them.

## A second problem found, for its own task

Nothing new. The one stage 1 reported — `packages/api/readme.md` and
`ARCHITECTURE.md` both link to a `DEPLOY.md` that does not exist in the
repository — is still there, still pre-existing, and I left it alone; my
readme edits do not add a new link to it.

One small robustness fix I did make, because I was adding three roles to the
same teardown: `scripts/database.py`'s `drop_role` now returns early when the
role does not exist. `DROP OWNED BY` has no `IF EXISTS` form, so a run of
`scripts/integration.sh` that failed before provisioning would have had its
cleanup trap fail too.

## Follow-ups

1. **Nothing rotates these passwords.** Re-running `tsdhn-queue-grants` with a
   new value issues `ALTER ROLE ... PASSWORD`, so the mechanism exists, but
   there is no documented rotation order (grant first, then restart the
   processes) and no `DEPLOY.md` to put it in.
2. **`compute.jobs` still has no retention.** Out of scope here and correctly
   so, but the asymmetry is now explicit in `ARCHITECTURE.md` and someone will
   ask.
3. **The two compose e2e scripts still have not been run** (stage 1's
   follow-up 4). They now also need the three new `.env` values, which I added
   to both workflows but could not exercise.

## Stage 2 resync onto the current migration tip

This task was re-landed from `27d2a3e`, the current tip of
`cap/picv-asyncpg-rqueue-v2`, rather than applying the old operability diff to
the stale worktree. I copied only the two genuinely new files from the old
attempt (`api/queue_grants.py` and `tests/test_queue_roles_integration.py`)
and re-added the role DSNs, queue-role provisioning, retention task, runtime
wiring, and documentation on top of the current parent files.

The final `tasks.py` still contains `WorkspaceClaim`, `claim_workspace`, and
`remove_workspace`; `db.py` still contains `owner_attempt`'s SQLSTATE-class
transient-error handling; and `repository.py` is byte-for-byte unchanged from
the parent tip. The final diff against the parent shows only the operability
additions in `tasks.py` and `db.py`, and no diff at all in `repository.py`.
The workspace remains uncommitted as requested.

Verification on the resynced tree:

```
uv run ruff check ...                 -> All checks passed!
uv run ruff format --check ...       -> 31 files already formatted
uv run mypy --strict packages/api     -> Success: no issues found in 28 source files
uv run pytest -n auto -m 'not integration'
                                      -> 236 passed, 14 skipped
bash scripts/integration.sh          -> 57 passed, 91 deselected
web test:integration                  -> 2 passed
```

The integration run applied both schemas, ran the real `tsdhn-queue-grants`
entry point, and passed all 15 real-role privilege tests, including the real
producer enqueue/worker claim path and purger retention cascade checks. An
initial integration invocation stopped before tests because this checkout had
not installed the web dependencies:
`web db:migrate: /usr/bin/bash: line 1: drizzle-kit: command not found`.
After the documented `bun install`, the complete integration run passed as
shown above. No new second problem was found.

## Gate round 1 fixes

The broken unprovisioned-purger fallback is fixed. When
`COMPUTE_PURGER_PASSWORD` is absent, `purge_pool` now opens a separate pool
against `COMPUTE_DATABASE_URL`; it never reuses the worker's CONSUME pool, so
the development fallback retains DELETE capability. The integration suite
now exercises the fallback through an actual purge and verifies the session
is the owner role.

Retention now checks old terminal queue candidates through the worker's
compute-readable pool, joining `task_queue.jobs` to `compute.jobs`, and only
deletes IDs whose compute rows are already terminal. The purger pool remains
queue-only and performs the final DELETE. An old queue row paired with a
running, missing, or malformed compute row is retained for reconciliation.
The unit and real-role integration tests cover this case.

Verification after the gate fixes:

```
ruff check / format                 -> All checks passed; 96 files formatted
mypy --strict packages              -> Success: no issues found in 94 files
uv run pytest -n auto -m 'not integration'
                                    -> 236 passed, 14 skipped
bash scripts/integration.sh         -> 58 passed, 97 deselected
web test:integration                -> 2 passed
docker compose config               -> valid
```

## Gate round 2 fixes

The API package setup instructions again require `APP_DB_PASSWORD`, alongside
the three queue-role passwords; this is required because compute migration
still provisions the web role.

Retention keeps its worker-side compute eligibility check, and the purger
DELETE now independently rechecks queue, terminal state, and retention age in
its own `WHERE` clause. A concurrent `Admin.retry_job` therefore cannot move a
row back to pending and still have the stale candidate delete its history.

Queue-role provisioning now rejects duplicate producer, worker, or purger role
names before making any database changes. Role-DSN rewriting now preserves the
authority verbatim, so valid asyncpg Unix-socket and multi-host DSNs receive
new credentials without hostname/port parsing assumptions. The queue-role
docstring was also corrected to describe rqueue's actual RLS coverage; no
rqueue grants or papercuts were changed.

Verification after Round 2:

```
mise run lint                       -> All checks passed; mypy: 95 files
uv run pytest -n auto -m 'not integration'
                                    -> 239 passed, 14 skipped
bash scripts/integration.sh         -> 58 passed, 100 deselected
web test:integration                -> 2 passed
```

## Gate round 3 fix

`_grant_compute_access` now unconditionally revokes `CREATE` on the `compute`
schema before applying the role's allowed `compute.jobs` access. A real-role
regression test grants schema `CREATE` drift to worker and purger roles,
re-runs provisioning, and verifies both privileges are removed. No rqueue
grant behavior or tracked papercut was changed.

Final verification:

```
mise run lint                       -> All checks passed; mypy: 95 files
uv run pytest -n auto -m 'not integration'
                                    -> 239 passed, 14 skipped
bash scripts/integration.sh         -> 59 passed, 100 deselected
web test:integration                -> 2 passed
git diff --check                    -> passed
```

## Pre-ship cleanup

Removed the unused `worker_pool` parameter from `purge_pool` and updated both
the worker and integration-test call sites to use `purge_pool()`.

Final verification remained green:

```
mise run lint                       -> All checks passed; mypy: 95 files
uv run pytest -n auto -m 'not integration'
                                    -> 241 passed, 14 skipped
bash scripts/integration.sh         -> 59 passed, 102 deselected
web test:integration                -> 2 passed
git diff --check                    -> passed
```

## Gate round 4 fixes

The purger role now receives an idempotently recreated restrictive DELETE RLS
policy on queue `jobs`, allowing only rqueue terminal states. It composes with
rqueue's existing permissive queue-scope policy, so direct purger connections
cannot delete pending or leased jobs even if application filtering regresses.
The existing worker-side compute-terminal check remains unchanged. The real
purge tests verify that pending direct deletes leave the row intact while
terminal deletes still succeed.

Queue-role startup validation now rejects producer, worker, or purger names
that collide with `APP_DB_ROLE` or the username parsed from
`COMPUTE_DATABASE_URL`, in addition to rejecting collisions among the three
runtime roles. The check runs before any provisioning changes.

Final verification:

```
mise run lint                       -> All checks passed; mypy: 95 files
uv run pytest -n auto -m 'not integration'
                                    -> 241 passed, 14 skipped
bash scripts/integration.sh         -> 59 passed, 100 deselected
web test:integration                -> 2 passed
git diff --check                    -> passed
```
