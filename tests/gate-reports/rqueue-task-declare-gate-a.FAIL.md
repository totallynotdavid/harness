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

GATE: FAIL
