I'll start by reading the code rules, then examine the diff.
Verified live against the installed harnesses (`claude` 2.1.267, `codex` 0.153.4): both `cap-ask` paths run end to end (`./bin/cap-ask haiku` and `./bin/cap-ask rival` both returned their answer, rc=0), the stream-json result schema the rewrite depends on is correct (`usage.iterations[]` snake_case, `modelUsage.<key>.{contextWindow,canonicalModel}` camelCase, `api_error_status`, `rate_limit_info.resetsAt` and `.unifiedWindows.*`), `--session-id`/`--resume` round-trip the same id, headless `/compact` is really executed, and the written usage record matches `cap-statusline`'s shape.

## Defects

**1. `gate_verdict` can record PASS for a report whose verdict is FAIL — `bin/lib.sh:581`**

Dropping `tail -15` means any exactly-matching line anywhere in the report is eligible. The gate prompt (`bin/cap-gate:33`) tells the reviewer to end with `GATE: PASS or GATE: FAIL`, so a report that restates that requirement on its own line puts a bare `GATE: PASS` in the file. If the real verdict is then written in a form the strict regex misses (`**GATE: FAIL**`, `GATE: FAIL.`, a fenced block), the quoted line wins.

Reproduced with both implementations on a 36-line report that quotes `GATE: PASS` at line 5 and ends with `**GATE: FAIL**`:

```
master gate_verdict : UNKNOWN
branch gate_verdict : PASS
```

Failure: `bin/cap-gate:93` writes `{"A":{"verdict":"PASS","fingerprint":<current>}}`; if B also passes, `gate_ready` (`bin/lib.sh:617`) returns 0 and `cap gate` prints `READY TO LAND`. A rejected review lands. On master the same report returned UNKNOWN, which `bin/cap-gate:86-91` handles safely — keep the previous report, record nothing, exit 2. The change removed the only way UNKNOWN can still be reached for a long report.

The comment at `bin/lib.sh:572-579` justifies the change with "any line matching exactly ... is a real verdict, not a substring match against instruction text the answer happens to quote". That is the inverted claim: an exact-line match is precisely what a quoting answer produces. The old defence was the window, not the anchoring.

**2. `bin/cap-check:45-46` still inlines the rule that is now `diff_base()` — `bin/lib.sh:548`**

`bin/lib.sh:544-545` says "bin/cap-check computes the same thing for the same reason", but `cap-check` sources `lib.sh` and re-derives `git merge-base "$base" HEAD` by hand. Failure: a later fix to `diff_base` (a base that only resolves as `origin/<name>`, a detached HEAD) reaches `cap gate` and not `cap check`, so the two commands report different change sets for the same task — the exact disagreement `diff_base` was added to remove.

**3. `bin/cap-ask:62` prunes a directory it does not own, at a second retention**

`cap-statusline:114-124` already sweeps `state/usage` at 1 day; this adds a 7-day sweep of the same directory, so in a normal install the effective retention is whichever ran last and the 7-day rule is dead. The glob also matches `codex_cached`'s caches, which live in `CAP_USAGE_DIR` (`bin/lib.sh:882`, `949`: `codex-models.json`, `codex-limits.json`) — harmless, since they are caches, but not what the comment describes.

**4. Compact-then-continue never checks that the compact happened — `bin/cap-ask:107`**

`/compact` is queued as turn 1 and turn 2 runs regardless of its answer. Confirmed live that headless `/compact` can return `is_error:false` with `result:"Not enough messages to compact."`; the code then resumes an uncompacted session, which the policy at `bin/cap-ask:69-71` says must never happen. Only reachable via `CAP_ASK_RESUME=force`, which no caller sets, so the cost today is latent.

**5. `docs/pipeline-notes.md:103-124` overstates how often direct resume fires**

The result event's `usage` is per-turn, not cumulative: a resumed turn that made no API call reported `iterations: []` and all-zero usage on a session already holding 13,607 tokens. So `.usage.iterations[-1]` is null for any turn rejected before its first iteration, `ctx_pct` is 100, and `cap gate` — which never sets `CAP_ASK_RESUME=force` — always takes the "starting fresh" branch with a warning. The code is behaving as `bin/cap-ask:182-186` intends; the doc reads as if under-30% resume is the ordinary path.

GATE: FAIL
