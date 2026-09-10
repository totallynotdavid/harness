Recovered from the reviewer's own session transcript: the pane capture (herdr's
999-line hard ceiling) dropped everything above finding 3, including the header
and findings 1-2, on this review specifically because it ran long (8m49s,
extensive tool use). Recovered the same way the original cap-ask truncation fix
and local-env's dropped finding were diagnosed. See paper-cuts.md.

Baseline: `mise run lint`, the 158-test fast suite, and the 102-test integration suite all pass on this worktree. The defects below are outside what those cover.

## 1. `declare_task()` is unusable on any queue with a customised `default_retry`

`src/rqueue/queue.py:267-279` — `_validate_declaration_retry` resolves `retry=None` to `self.default_retry` and *then* applies the "no worker hooks" guard to it:

```python
resolved = self.default_retry if retry is None else retry
if resolved.retry_if is not None or tuple(resolved.retry_on) != (Exception,):
    raise ConfigurationError("declare_task retry may only configure numeric settings; ...")
```

`default_retry` is a public constructor parameter (`queue.py:96`). Any queue built with one that narrows `retry_on` — the normal reason to pass it — cannot declare a task at all, and the error blames an argument the caller never supplied. `register()` on the same queue handles the identical value by *stripping* the hooks (`_new_registration_declaration`, `queue.py:246-265`), so the two entry points disagree.

```
$ uv run python …
register OK -> RetryPolicy(max_attempts=5, …, retry_on=(<class 'TimeoutError'>,), retry_if=None)
declaration  -> RetryPolicy(max_attempts=5, …, retry_on=(<class 'Exception'>,), retry_if=None)
declare_task(no retry arg) FAILED: ConfigurationError | declare_task retry may only configure numeric settings; retry_on and retry_if belong to register()
```

It is also order-dependent, because the repeat path skips the guard entirely (`queue.py:141-148`):

```
A: declare_task first -> ConfigurationError declare_task retry may only configure numeric settings; retry_on and retry_if belong to register()
B: register then declare_task -> OK, (<class 'Exception'>,)
```

Same queue config, same call — raises or succeeds depending on which was called first.

## 2. The malformed-policy quarantine in `Storage.claim` is unreachable, and the case it targets wedges the worker

`src/rqueue/storage.py:249-293` catches `ConfigurationError` from `Job.from_row(row, strict_retry_policy=True)` and fails the row via `fail_invalid_policy` (`storage.py:868-880`). It never runs. `lease_jobs` UPDATEs the job row, and PostgreSQL re-evaluates `jobs_retry_policy_shape` on the new tuple — including for a constraint added `NOT VALID` — so the statement aborts before any row reaches Python. Reproduced against a migrated database with a hand-corrupted row, calling the real `Storage.claim`:

```
row: <Record id=UUID('e1eeea86-…') state='pending' attempt=0 retry_policy='{"nonsense": true}'>
claim raised: asyncpg.exceptions.CheckViolationError
  isinstance PostgresError: True
  message: new row for relation "jobs" violates check constraint "jobs_retry_policy_shape"
```

The consequence is worse than no defense. `CheckViolationError` is an `asyncpg.PostgresError`, so `Worker._loop` (`worker.py:308-317`) swallows it as `_DB_ERRORS`, logs `"rqueue: worker %s could not reach PostgreSQL; retrying"`, backs off 1s and loops. `claim_candidates` re-selects the same pending row on every poll, so one bad row stops the worker from claiming *any* job, indefinitely, behind a log line that points the operator at connectivity.

The integration test that appears to cover this — `tests/integration/test_operations.py:229-244` — drops the constraint first:

```python
await connection.execute(
    f"ALTER TABLE {schema}.jobs DROP CONSTRAINT jobs_retry_policy_shape"
)
```

so it validates a schema state migration 0004 never produces (it ends with `VALIDATE CONSTRAINT`). The ~45 lines of quarantine logic, the `fail_invalid_policy` statement, and the `strict_retry_policy` flag are all cost with no delivered resilience.

## 3. Dead cross-validation branch, duplicated, in `TaskRegistration.__init__`

`src/rqueue/tasks.py:94-124`. The `declaration=` + `name=`/`retry=`/`timeout=` combination has no production caller: `Queue.register` passes `declaration=` alone (`queue.py:216-220`), and so does `for_job` (`tasks.py:175-179`). Only `test_task_registration_validates_retry_with_a_declaration` reaches it. Those 30 lines also restate `Queue._check_declaration_options` (`queue.py:281-306`) nearly verbatim — the same two comparisons, the same two messages — which is the coincidental-similarity duplication `rules/code.md` warns against, not a shared reason to change.

Lines 119-124 add a third path inside the same constructor: after proving the two policies' numeric data equal, it rebuilds the declaration when the objects differ by identity. A frozen dataclass constructor that reconstructs its own field is ceremony without active value.

The hand-rolled dual-form `__init__` also reimplements what `@dataclass` supplies (`raise TypeError("missing required argument: 'name'")`, manual `object.__setattr__`, manual `self.__post_init__()`), for a legacy shape no caller in this repo uses.

## 4. `strict_retry_policy` is a boolean mode argument, and its default hides corruption

`src/rqueue/models.py:92-105`. `rules/code.md`: "Avoid boolean mode arguments; split behavior into separate functions." Given finding 2, the `True` branch has no reachable production caller, and the `False` default silently maps a corrupt persisted policy to `retry_policy=None` — which `Queue.get_job`, `Admin`, and the CLI then render identically to a legacy pre-0004 row that genuinely has no policy. An operator inspecting the row gets no signal that data was discarded.

## 5. Undocumented behaviour change: a plain `register()` now freezes backoff onto every job row

`register()` populates `_declarations` (`queue.py:227-229`), and `build_insert` materialises that policy onto every job (`queue.py:471-476`) — not just for `declare_task` users. `for_job` then treats the row as authoritative over the worker's local policy (`tasks.py:161-169`). On `master`, editing `RetryPolicy(initial_backoff=…)` in worker code took effect immediately for already-queued jobs; now it does not until the *producer* is redeployed. The README change only states this inside the `declare_task` section ("The declaration is the single source of truth…"), so an existing single-process user gets the new precedence with no note that it applies to them.

GATE: FAIL
