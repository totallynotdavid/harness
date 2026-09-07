# rqueue scope-gap report

Date: 2026-09-02

## Result

I found two genuine scoping gaps. The most important is consumer-facing testing
ergonomics. The second is durable queue-wide pause/resume control. Both are
documented capabilities in mature queue libraries, neither is required by
`REQUIREMENTS.md`, and neither is among its explicit v1 non-goals.

This was a source/documentation comparison, not an implementation audit. I
read rqueue's public modules (`src/rqueue/__init__.py`, `queue.py`,
`worker.py`, `admin.py`, `scheduler.py`, `cli.py`, and `metrics.py`),
`README.md`, all of `REQUIREMENTS.md`, and the local README/docs/public APIs
for pgqueuer, Procrastinate, Oban, River, and Que. I did not change rqueue
code.

## Ranked gaps

### 1. Consumer-facing enqueue assertions and local worker execution

**What it is.** Procrastinate has a public
`procrastinate.testing.InMemoryConnector`; it provides an ephemeral connector
with inspectable `jobs`, resettable state, and connector behavior intended for
tests (`.../procrastinate/testing.py:22-43`). Pgqueuer documents
`PgQueuer.in_memory()` for unit testing and prototyping, explicitly noting that
it is non-durable and not for multi-process coordination
(`.../janbjorge-pgqueuer/docs/reference/in-memory.md:1-18`). Oban's testing
surface is broader: `Oban.Testing` supports `:inline` and `:manual` modes,
`assert_enqueued`, `refute_enqueued`, `all_enqueued`, and `perform_job`
(`.../sorentwo-oban/guides/testing/testing.md:11-67`,
`testing_queues.md:8-15`, `testing_workers.md:1-17`).

Rqueue has no equivalent adapter or test helper in its public exports or
implementation. `Queue` requires an `asyncpg.Connection` for enqueueing and
`Worker` requires the real queue/pool path. Rqueue's own suite correctly has
database-free validation tests, but its integration suite is explicitly a
real-PostgreSQL suite (`tests/integration/conftest.py:1-5, 19-36`).

**Picv-2025 need.** This is directly useful. The consumer already has a thin
enqueue seam: `repository.create_or_get_job(..., defer=...)` and a unit test
that substitutes a fake configured task and records the deferred payload
(`picv-2025/packages/api/tests/test_tasks.py:202-230`). That proves the current
code can test the seam, but it does not verify the actual rqueue call's task
name, JSON payload, queue, dedupe key, conflict mode, or concurrency key
without either hand-written fakes or a database. The repository integration
tests create disposable PostgreSQL databases (`.../tests/conftest.py:17-35`),
which is appropriate for database behavior but expensive for ordinary
"enqueue the right job" tests.

**Judgment: genuine gap; make a deliberate build decision.** Add a small,
clearly non-durable testing surface—probably an injectable producer/test
connector or a pure enqueue-recording helper, plus a worker `perform`/drain
helper—whose contract is to validate and capture requests without pretending
to test PostgreSQL transactionality. It should preserve the production
callback shape and make the distinction from the required integration tests
explicit. If maintainers do not want to own this API, add “no fake/in-memory
consumer connector; consumers must mock the enqueue seam or use PostgreSQL”
to §9. Leaving it unstated makes every consumer independently rediscover the
same testing decision.

### 2. Durable queue-wide pause/resume for operations

**What it is.** Oban documents independent queue control, including starting,
stopping, pausing, resuming, and scaling queues
(`.../sorentwo-oban/README.md:84-91`). River exposes transactional
`QueuePause`/`QueueResume`; a paused queue stops clients fetching new jobs,
and notifier-enabled clients learn of the change shortly after commit
(`.../riverqueue-river/client.go:2675-2712, 2744-2756`). This is distinct from
stopping one worker process: it is durable/shared control over all workers for
a queue.

Rqueue's operational surface has `Worker.stop()`, `Worker.drain()`, readiness,
purge, retry/cancel, and schedule enablement, but no queue pause state or
admin/CLI operation. The README says `Worker.stop()` only asks that worker's
loop to finish and return, while `drain()` is a one-shot operation
(`README.md:127-136`); `Admin`'s listed operations contain no pause/resume
(`README.md:256-264`).

**Picv-2025 need.** Plausible, but not demonstrated as an immediate product
requirement. A compute queue may need to stop admitting new simulations during
maintenance, a deploy, an upstream outage, or a resource incident while
allowing existing leased work to finish. Today that requires coordinating the
worker processes or changing deployment configuration; `Worker.stop()` does
not prevent another replica from claiming jobs. This is a production
operability concern rather than a missing execution primitive, and the
requirements already care about worker/scheduler liveness and database
restarts (`REQUIREMENTS.md:293-297, 336-346`).

**Judgment: genuine gap worth an explicit decision, probably defer/build only
if operations require it.** Add a durable pause flag with an admin/API and
notification semantics, or explicitly reject it in §9 as unnecessary for a
single-consumer deployment whose workers are controlled by its supervisor.
Do not mistake `stop()` or `drain()` for this feature.

## Testing ergonomics verdict

This deserves its own verdict: rqueue has no equivalent to
`InMemoryConnector`, `PgQueuer.in_memory()`, or `Oban.Testing`. Picv-2025 would
benefit from one for unit-level enqueue assertions, while continuing to use
its disposable PostgreSQL tests for transactionality and integration behavior.
This is the clearest scope blind spot in the contract.

## Candidates deliberately not reported as gaps

- **Transactional enqueue, retries, delayed jobs, cron, cancellation,
  concurrency, priority, deduplication, retention, metrics, readiness, and
  least-privilege operations** are already required and implemented in the
  stated rqueue scope (`REQUIREMENTS.md:106-168, 220-297`; `README.md:138-201,
  219-268`). In particular, `dedupe_key` and `concurrency_key` cover the
  superficially similar “unique jobs” and resource-lock features.
- **Fencing and occurrence-key scheduling** are already deliberate design
  choices. `REQUIREMENTS.md` directly evaluates pgqueuer and River's
  heartbeat/leader approaches and commits to lease tokens and the occurrence
  table (`REQUIREMENTS.md:36-61, 256-278`). They are not blind spots.
- **Completion watchers / waiting for job groups** are documented by pgqueuer
  (`README.md:15-18, 138-139`), but picv-2025 already exposes and consumes
  application-owned job status and event streams, while rqueue's contract
  requires observable state rather than a queue-level waiter. I would not add
  this to the scope based on the available evidence.
- **Per-entrypoint limits, global rate limiting, progress/output recording,
  plugin/middleware ecosystems, and dashboards** are either already covered
  by rqueue's worker/concurrency/context/metrics design, are Oban Pro features
  rather than the free core, are application-level concerns for picv-2025, or
  are explicitly rejected by §9 (especially plugins and dashboards). They do
  not clear the contract's “filter hard” bar.
- **Sync handlers** are not a gap: §4 explicitly chooses async-only handlers
  with `asyncio.to_thread`, and records that pgqueuer removed its sync-entrypoint
  path (`REQUIREMENTS.md:197-218`).

## Verification failure

The requested fast-test command could not run in this checkout because the
environment has no pytest executable:

```text
$ pytest -q
/bin/bash: line 1: pytest: command not found
exit_code=127
```

No code was modified; the rqueue worktree remained clean after the review.

Genuine scoping gaps found: 2. Single most important: consumer-facing enqueue/testing ergonomics.
