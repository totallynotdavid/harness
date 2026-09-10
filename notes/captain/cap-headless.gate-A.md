I'll start by reading the code rules, then survey the diff.
## Defects

**1. A resumed session that emits no result event wedges the profile permanently — `bin/cap-ask:150-155`**

`[ -n "$result_json" ] || break` exits the turn loop, and line 155 dies before the `rm -f "$match_file"` at line 212 ever runs. The pending `state/ask-resume/<id>.json` survives, so the next identical call resumes the same dead session and dies the same way, forever. The comment at 205-211 states this is exactly the loop the change set out to close; the fix covers only the path where a result event exists.

Reproduced against a stubbed harness that exits without writing stdout:

```
before: dead-session.json
cap: claude produced no result event for its last turn; see .../state/ask/dead-session.jsonl
exit=1
after:  dead-session.json
```

Second run, byte-identical. `cap gate <slug>` fails this way until someone deletes the record by hand.

**2. Harness stderr is discarded, so the error it dies on points at an empty file — `bin/cap-ask:145` and `:233`**

`(cd "$dir" && "${cmd[@]}" </dev/null >"$turn_out" 2>/dev/null)` throws away everything the harness said about why it failed. Same on the codex side. With a stub that prints a real startup failure:

```
cap: claude produced no result event for its last turn; see .../3195256d-....jsonl
--- transcript contents ---
(end)
```

`Invalid API key . Please run /login` is gone, and the operator is handed a 0-byte transcript. Master surfaced this through the pane capture. `rules/code.md`: "return explicit errors with actionable context."

**3. Orphan resume records are never pruned, and lookup is now O(n) subprocesses — `bin/cap-ask:56-58`, `:78-86`**

Master keyed the record by a hash filename: one `[ -f ]` test, one file per (profile, dir, prompt, key), overwritten in place. The new scheme names records by session id and runs a separate `jq -e` over every `*.json` in the directory on every claude call. A record is deleted only when a later call matches it exactly — but `cap-gate` puts the diff fingerprint in the key *and* the merge-base SHA in the prompt, so once the worktree changes (the normal outcome of a gate finding something) that record can never match again. Line 58 added a 7-day sweep for `state/ask` transcripts; nothing sweeps `state/ask-resume`. `grep -rn ask-resume bin/` returns one line, the directory assignment.

**4. `rl_resets` is empty rather than `0` when the turn carried no rate-limit event — `bin/cap-ask:172`**

`jq -r '.rate_limit_info.resetsAt // 0' <<<""` reads no input: it prints nothing and exits 0, so the `|| echo 0` never fires and the `// 0` never applies. Verified:

```
rl_resets=[] rc-of-date=(fell back)
```

The two session-limit signals that need no `rate_limit_event` — `api_error_status = 429` and `terminal_reason = blocking_limit`, lines 183 — are precisely the ones that land here. `profile_block "$profile" ""` then silently falls back to `CAP_BLOCK_SECS` (1h) instead of the real reset, and the die message reads "resets an unknown time". If the real window is four hours out, the profile unblocks early and the next round buys another rejection.

## Checked and clean

`mise run lint`, `check:andlist`, `check:syntax` all pass. `limit_reset_epoch` has no remaining callers; `require_herdr` is still used by `cap-spawn`/`cap-send`. `usage_write` verified against a captured `rate_limit_event`: `utilization` is a 0-1 fraction and `resetsAt` epoch seconds, so `*100` is right and `usage_read`/`usage_detail` read the file back correctly (`35 1789057200 snapshot`). `gate_verdict`'s unbounded scan is safe — `tail -1` keeps the last real verdict line, and quoted instruction text does not match. All `codex exec` and `claude -p` flags used exist. `diff_base` is consistent between `cap-gate`'s prompt and `gate_fingerprint`/`gate_ready`, and matches `cap-check:45`.

<cc-memory filenames="log-captain-friction-to-papercuts.md">These four belong in `paper-cuts.md`; I did not add them there because this gate forbids edits.</cc-memory>

GATE: FAIL
