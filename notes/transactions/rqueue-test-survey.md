# rqueue test-suite survey

## Scope and method

I read the current rqueue tests under `tests/` and `tests/integration/`, plus
the test files in the local pgqueuer, Procrastinate, Oban, River, and Que
checkouts. I compared scenarios by behavior, not by test name. The rqueue
suite is 4,204 lines across 25 test files, with a deliberate split between
offline validation and real-PostgreSQL integration tests.

The local verification result was:

```text
$ pytest -q tests
/bin/bash: line 1: pytest: command not found
```

Using the repository runner instead:

```text
$ uv run pytest -q tests
99 passed, 78 skipped in 0.82s
```

The 78 skips are the PostgreSQL integration tests, each skipped because
`RQUEUE_ADMIN_DATABASE_URL` is unset. No test failure was observed after
installing the declared environment with `uv run`.

## Ranked findings

### 1. Add public worker lifecycle edge-case tests: stop-before-start and hard task cancellation

**What the mature suites test.** Procrastinate has explicit worker lifecycle
tests in `tests/unit/test_worker.py`: stopping an idle worker, cancelling its
`run()` task, stopping before the run loop starts, and stopping after the run
has already exited with an error. Its integration
`tests/integration/test_wait_stop.py` also tests SIGTERM and the polling wait.
pgqueuer has analogous shutdown coverage in
`test/test_qm.py`, including shutdown arriving after rows have been picked but
before dispatch (`test_shutdown_mid_batch_leaves_no_stranded_picked_jobs`),
and `test/test_sigterm_cancellation.py` covers cancellation of in-flight
dispatch and release of a concurrency slot.

**Why it matters to rqueue.** rqueue's public `Worker` lifecycle promises are
meaningful: `stop()` should finish or hand back work, and `run()` is also an
ordinary asyncio task that callers may cancel. The implementation has separate
paths for a cooperative stop and a hard cancellation: `src/rqueue/worker.py`
lines 369-402 explicitly collapse the grace period when the run task is
cancelled, then attempt a fenced `WorkerShutdown` hand-back. A race before
`_started` is set, or cancellation while `_tick()` has claimed a batch but
before tasks are registered, is therefore worth exercising.

The existing equivalent is narrower: `tests/integration/test_resilience.py`
lines 93-138 starts a worker, waits for a handler to be in flight, calls
`stop()`, and verifies the job is handed back and later succeeds. That does
not cover the lifecycle races above. This recommendation stays within the
house style: use a real Queue/Worker and assert durable job state, not mocks or
private call counts.

**Merit judgment: genuinely worth adding.** This is a small, high-value set
of tests around a public API and shutdown correctness. It is more important
than adding OS signal handling itself: rqueue does not expose a worker CLI or
promise that `Worker.run()` installs signal handlers, so signal-specific tests
from Procrastinate do not directly apply.

Suggested concrete cases:

1. Call `worker.stop()` before awaiting `worker.run()` and verify it returns
   without claiming work.
2. Cancel a running `worker.run()` while idle and verify it terminates promptly.
3. Force cancellation at the claim/dispatch boundary and verify no job remains
   leased indefinitely; a successor eventually completes it.

### 2. Add one PostgreSQL query-plan regression test for claiming under backlog

**What the mature suites test.** pgqueuer's
`test/test_query_plan_regression.py` seeds a large real PostgreSQL backlog,
runs `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`, and asserts that dequeue uses
the intended partial/index-backed access path, that the scan is proportional to
the batch rather than the whole table, and that existence/ETA queries retain
their `LIMIT` shape. This is a database-level regression test rather than a
mocked SQL-string test.

**Why it matters to rqueue.** Claiming is the queue's hot path. rqueue already
tests the intended SQL text (`tests/test_storage_sql.py` lines 66-77: `SKIP
LOCKED`, deterministic ordering, and lease-token predicates) and tests runtime
correctness under contention (`tests/integration/test_review_stress.py` lines
17-59). Those tests can still pass after an index is accidentally removed or
the query is rewritten into a plan that scans a large jobs table. A modest
real-DB plan guard with a representative pending-job backlog would protect the
operational property without inspecting Python internals.

**Merit judgment: worthwhile, but lower priority than lifecycle coverage.**
Keep it to one focused claim-plan test and a stable invariant (for example,
the relevant index or a bounded scan shape), not brittle exact-cost numbers.
If rqueue's intended deployment scale is explicitly small and performance is
outside the support contract, this can reasonably be deferred. It is the one
database-testing pattern from pgqueuer that has a plausible rqueue-specific
correctness/operability payoff and is not already present; the other pgqueuer
tests for alternate drivers, web integrations, tracing, in-memory adapters,
and driver-specific settings do not apply.

## Patterns examined but not gaps

- **Lease expiry, crash recovery, stale writers, and bounded retries:** already
  unusually strong in `tests/integration/test_fencing.py`, including a real
  doomed worker and all stale-token write operations. Do not add a generic
  “lease expiry” test.
- **Dedupe races and concurrency-key contention:** covered by the 32-producer
  and multi-worker stress cases in `test_review_stress.py`; the distinction
  between dedupe and concurrency keys is also tested directly.
- **Transactional enqueue and atomic batches:** covered by
  `test_transactional_enqueue.py`, including rollback of business data and
  queue data, same-connection use, whole-batch validation, and conflict
  behavior.
- **Notifications and polling:** stronger than most references: rqueue disables
  the PostgreSQL triggers to prove missed `NOTIFY` only adds latency, and has a
  positive wakeup test (`test_resilience.py` lines 50-90).
- **Database outage/restart:** covered both by terminating all backends and,
  when the test owns the cluster, by stopping and starting the actual
  postmaster (`test_resilience.py` lines 141-267).
- **Property-based testing:** Oban uses properties for backoff and cron bounds,
  but rqueue already has focused boundary/parameterized tests for backoff,
  cron ordering, time zones, DST, validation, and overflow. Introducing a
  property-testing dependency would add maintenance cost without a demonstrated
  uncovered state space. This is not a gap worth opening now.
- **Signals, broker adapters, language-specific supervision, tracing plugins,
  and in-memory backends:** these are real concerns in the reference projects,
  but rqueue deliberately has no equivalent public surface or failure model.

## What rqueue tests that the mature suites notably do not

rqueue's most distinctive tests are also its strongest evidence of quality:

- `test_fencing.py` verifies opaque lease-token fencing, whereas pgqueuer and
  River use heartbeat-timeout recovery and do not prevent a slow stale worker
  from writing after reclaim.
- `test_transactional_enqueue.py` verifies queue writes on the caller's exact
  asyncpg connection and the business-row/queue-row atomicity required by this
  package.
- `test_operations.py` verifies RLS-scoped least-privilege producer/app roles,
  including prohibited updates. None of the inspected mature suites showed an
  equivalent capability-boundary test.
- `test_resilience.py` performs a real postmaster stop/start test when the
  local database is owned by the test run, not merely an in-process fake.
- `test_worker_concurrency.py` proves the bounded default executor for explicit
  `asyncio.to_thread()` work, including a positive control with the bound
  disabled.

These are valuable rqueue-specific guarantees, not ceremony to remove merely
because older or larger projects do not test them.

## Bottom line

rqueue's current coverage is already comparable to the mature suites for queue
correctness; the two concrete gaps worth considering are public worker
lifecycle race tests and one real-PostgreSQL claim query-plan regression test,
with lifecycle coverage the clear priority.
