I'll start by reading the code rules, then examine the diff.
## Defects

**1. `ctx_pct` is measured from the turn that was refused, so the resume policy inverts its own fail-safe — `bin/cap-ask:177-182`**

The 30% branch at `bin/cap-ask:81` decides whether to resume a rejected session directly or compact it first. The number it branches on is computed from the rejected turn's own token accounting. A turn stopped by a 429 never replays the session prefix, so `cache_read_input_tokens` is absent and the sum is just the new prompt.

Against the repo's own captured rejection, `state/ask/a7195ba1-ca4a-4351-aba7-8a11e86540f5.jsonl`:

```
{"type":"result","subtype":"error","is_error":true,"api_error_status":429,
 "terminal_reason":"blocking_limit","usage":{"input_tokens":100},
 "modelUsage":{"claude-haiku-4-5-20251001":{"contextWindow":200000,...}}}
```

Running the shipped expression over it:

```
$ jq -r '((.usage.input_tokens // 0) + ... ) as $used | ... | ($used / $win * 100 | floor)'
0
```

Failure: a session rejected at 90% context is recorded as `ctx_pct: 0`, takes the `-lt 30` branch, and is resumed uncompacted — the case `bin/cap-ask:65-66` says must never happen. The `CAP_ASK_RESUME=force` compact-first branch (`:83-85`) becomes unreachable, since it is only reached when the recorded value is ≥30. It is not always zero — a turn that made several successful tool round trips before the 429 accumulates real `cache_read` — but it is zero in exactly the case the change captured and documented.

The replaced code read `ctx N% used` off the pane, which was the session's real usage, and defaulted to `100` when it could not find it. The new code defaults to `100` only if `jq` itself errors; a computed `0` is trusted. The fail-safe direction flipped from "start fresh when unsure" to "resume when unsure".

**2. `state/usage` has no pruner on the headless path — `bin/lib.sh:1046-1089`**

`usage_write` adds one file per headless call. The only code that deletes from that directory is `bin/cap-statusline:110-118`, and the diff's own doc change (`docs/pipeline-notes.md:264-268`) states a headless call never renders a status line. `usage_read` (`bin/lib.sh:983`) and `bin/cap-models:54` both slurp `"$CAP_USAGE_DIR"/*.json` on every sizing decision.

Failure: on a box running Captain headless — the case this branch exists for — the directory grows one file per `cap ask`/`cap gate` round with nothing reclaiming it, and every dispatch-sizing read parses all of them. `cap-ask:56-57` prunes `state/ask` and `state/ask-resume` on a 7-day sweep and skips this one.

**3. `diff_base` extracted, two of its copies left behind — `bin/lib.sh:537`, `bin/cap-check:45-46`, `bin/cap-cleanup:16`**

The new helper's comment says `bin/cap-check` "computes the same thing for the same reason", and both `cap-check:45-46` and `cap-cleanup:16` still hand-roll `git merge-base "$base" HEAD` with the same fallback. Three definitions of where a branch left base. No runtime failure today; the failure mode is drift, and `rules/code.md` calls for one consistent term per concept across modules.

**4. `"${result_json:-{}}"` is not the guard it looks like — `bin/lib.sh:1069`**

Bash closes the expansion at the first `}`, so this is `${result_json:-{}` plus a literal `}`:

```
$ bash -c 'y=A; echo "[${y:-{}}]"'
[A}]
```

The here-string carries the JSON with a trailing `}`. `jq` prints the first value and then exits 5 on the junk; `2>/dev/null || true` swallows both, and the empty case happens to expand to `{}` anyway. No failure — it works by accident on both paths.

**5. Two comments do not describe their code**

- `bin/cap-ask:55` — the pruning comment ends with an aside about `dispatch_log`, which neither `find` touches.
- `bin/cap-ask:120-122` — "Each turn writes to its own file first so a death without a result leaves nothing to fall back to" states the opposite of the reason. The per-turn file exists so `result_json` reflects the current turn instead of matching an earlier turn's result already appended to `$jsonl`.

## Verified working

`mise run lint`, `check:andlist`, `check:syntax` pass. Live end-to-end: `cap ask haiku` returned in 2.8s, wrote `state/usage/8ed5a015-….json`, and `cap budget` read it back as `claude 60% (5h 60%, 7d 39%, read 4s ago)` — so `utilization × 100` and `resetsAt` are the right shapes. Confirmed against a live session that headless `--resume` preserves the session id and that `/compact` executes as a real slash command in `-p` mode ("Not enough messages to compact."), so the two-turn compact path is sound. `codex exec` accepts `--json`, `-C`, `-o/--output-last-message`. `limit_reset_epoch` has no remaining callers; `require_herdr` is still used by `cap-send`/`cap-spawn`. The error-shaped result the resume-clearing logic targets is real and matches (`errors: ["No conversation found with session ID: …"]`, `is_error: true`, no `api_error_status`).

GATE: FAIL
