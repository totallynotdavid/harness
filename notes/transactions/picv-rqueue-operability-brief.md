# picv-2025: use rqueue's role and admin surfaces, not just its worker

Stage 1 (`cap/picv-asyncpg-rqueue-v2`, see
`~/git/captain/notes/transactions/picv-asyncpg-rqueue-v2.md`) swapped
Procrastinate/psycopg for rqueue/asyncpg and works end to end, verified live
against a real database. This task builds on that branch (`--stack
picv-asyncpg-rqueue-v2`) and closes two gaps that stage 1 correctly scoped
out but flagged as real: the app connects to the queue schema as its owner
(no least-privilege roles), and nothing ever retires old `task_queue.jobs`
rows.

Read the stage 1 report above first -- it describes the current shape of
`api/core/db.py`, `queue.py`, `tasks.py`, `worker.py`, and `settings.py` in
detail, all of which this task builds on rather than re-explains.

## 1. Least-privilege roles for `task_queue`

`~/git/transactions/src/rqueue/roles.py` has a real capability system:
`Capability.PRODUCE`/`CONSUME`/`SCHEDULE`/`INSPECT`, `provision_role(...)`,
`grant_queues(...)`, `revoke_role(...)`. Read its module docstring and every
`Capability`'s exact grant set (`_TABLE_GRANTS`) before using it -- in
particular, `PRODUCE` gets a *column-scoped* `UPDATE (updated_at)` on `jobs`
on purpose (the dedupe-conflict path is `DO UPDATE SET updated_at = ...`,
not `DO NOTHING`), not a whole-table `UPDATE`.

picv-2025 already does the equivalent for its web layer:
`api/web_grants.py`/`APP_DB_ROLE`, run once at deploy time via the
`tsdhn-web-grants` entry point. Extend that pattern to the queue:

- The API process only ever calls `queue.enqueue(...)` (via
  `tasks.enqueue_simulation`) and reads job/queue state for `/health` and any
  future admin surface. That's `PRODUCE` (+ `INSPECT` if the API reads
  anything `PRODUCE` doesn't already cover -- check what `/health` or any
  status endpoint actually touches before assuming).
- The worker process claims, heartbeats, and finalizes jobs, and runs the
  periodic sweep. That's `CONSUME`.
- Decide whether to provision these roles from a new deploy-time script
  (mirroring `web_grants.py`'s shape) or extend an existing one
  (`migrate.py` already runs at deploy time and now also runs `rqueue ...
  migrate` via `docker-compose.yml`, per stage 1's report -- check whether
  role provisioning belongs there instead of a new file). Use your
  judgement; state which you picked and why.
- `provision_role` takes a `schema`/`queues` scope -- picv-2025 has exactly
  one queue (`simulations`, see `COMPUTE_QUEUE` in `settings.py`), so scope
  the grant to it rather than `("*",)` unless you find a reason multiple
  queues are coming.
- Update `db.py`'s pool construction (or wherever the DSN is built) so the
  API and worker processes actually connect as their new roles, not the
  schema owner -- provisioning a role that nothing then uses is not the
  improvement. Check how `APP_DB_ROLE`/`APP_DB_PASSWORD` are wired into the
  web pool's connection string today and mirror that shape for the two new
  roles (new settings, e.g. `COMPUTE_PRODUCER_ROLE`/`COMPUTE_WORKER_ROLE`
  and their passwords).
- Verify with a real negative test, the way `bump`'s existing
  `test_web_role_cannot_...` tests do: the producer role cannot claim a job
  (no `UPDATE` beyond `updated_at`), the worker role cannot `DELETE FROM
  jobs` outright (only through the finalize paths rqueue's own SQL uses),
  neither role can run DDL.

## 2. Retention for `task_queue.jobs`

`~/git/transactions/src/rqueue/admin.py`'s `Admin.purge(queue=..., retention=
timedelta(...), states=..., limit=...)` deletes terminal jobs older than a
retention window; attempt and occurrence rows cascade with their job.
Nothing in picv-2025 calls this today, so `task_queue.jobs` grows without
bound.

- Add a periodic purge alongside the existing work-dir sweep in the worker
  process (`tasks.run_periodic_sweep`/`sweep_abandoned_work_dirs` in
  `tasks.py` -- read how that loop is built and either extend it or add a
  sibling task on the same `asyncio.Event`-driven shape, your call).
- Pick a retention window and state your reasoning -- `compute.jobs`
  (picv-2025's own business table) has no purge at all today and this task
  is not adding one; only `task_queue.jobs` is in scope. A terminal
  `task_queue.jobs` row has no value once `compute.jobs` has recorded the
  simulation's outcome (which happens immediately on completion/failure), so
  the retention window can reasonably be much shorter than
  `compute.jobs`' own retention would be -- but that's your call to make and
  justify, not mine to dictate.
- `Admin` needs its own pool (it's constructed with one, same shape as
  `Queue`/`Worker`) -- decide whether the worker process's existing pool is
  reused or a new one is opened; the existing pool is already provisioned
  for the worker's role from part 1, which may or may not have the right
  grants for `DELETE FROM jobs`/`job_attempts`/`schedule_occurrences` that
  purge needs -- check `Capability.CONSUME`'s grant set doesn't already cover
  it (it doesn't: `CONSUME` has no `DELETE` on `jobs`). You likely need
  either a third, purge-scoped role/capability combination, or to decide
  purge runs as the migration/owner role instead, the way `queue_migrate`
  work does. State your reasoning.
- Verify against a real database: seed terminal jobs older and younger than
  the cutoff, run purge, confirm only the old ones are gone and their
  attempt/occurrence rows went with them.

## Do not touch

- `relq` -- not used here.
- Anything already landed in stage 1 that isn't directly part of these two
  gaps. This is a small, additive task on top of a working branch, not a
  second pass over stage 1's design decisions.

## Verification

Real PostgreSQL, real roles, real negative-privilege tests, plus at least
one by-hand check: provision the roles for real, connect as each, confirm
what it can and cannot do matches the grant table you built, and confirm a
purge run actually removes only what it should.

## Deliverable

Leave changes uncommitted. Write a report to
`~/git/captain/notes/transactions/picv-rqueue-operability.md` covering both
parts: the roles you provisioned and their exact grants, the retention
window you chose and why, verification results, and anything you found that
contradicts this brief.
