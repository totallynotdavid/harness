I'll start by reading the code rules, then survey the diff.
Reviewed `git diff master` (4 files, no uncommitted changes) plus a live smoke test of the new headless path (`./bin/cap-ask haiku ... --dir /tmp` → returned `OK`, exit 0, wrote a correct `state/usage` record: `pct 69`, matching the status line's own 69).

## Defects

**1. `ctx_pct` can never fall under 30, so the whole resume-after-session-limit path is dead code.** `bin/cap-ask:188-195`, read back at `:84`.

Two independent reasons, both confirmed against transcripts on this box:

- The guard `if .usage.cache_read_input_tokens == null then 100` fires on every real rejection. The one captured 429 in this worktree, `state/ask/723a6856-9552-4e44-98b0-b2820e4e2a10.jsonl`, has `usage` = `{"input_tokens":100}` — no `cache_read_input_tokens` at all. So `ctx_pct` is 100.
- When `cache_read_input_tokens` *is* present, the sum is cumulative session spend, not live context occupancy. `cache_read_input_tokens` accumulates over every API call in the session. Measured on two real review-shaped sessions:

```
0b3a2786…jsonl  turns=55  win=1000000  cap-ask_ctx_pct=274%   actual_last_turn_ctx=10%
d8c952c7…jsonl  turns=49  win=1000000  cap-ask_ctx_pct=267%   actual_last_turn_ctx=10%
```

  It crosses 30 at about three turns (`5b9c32b1…jsonl turns=3 ctx_pct=35%`). A gate review is 40-60 turns.

Failure: every `cap gate` retry after a reset takes the `else` branch at `:89`, prints `starting fresh instead of resuming`, deletes the record, and pays for a cold session — the exact cost the mechanism exists to avoid. The `<30%` branch, the `CAP_ASK_RESUME=force` compact branch, `continue_prompt`, the two-turn compact loop, and ~35 lines of `docs/pipeline-notes.md` describing all of it are unreachable. The quantity that would work is the last `usage.iterations[]` entry (`input + cache_read + cache_creation + output`), which gives 10% for the same 55-turn session.

**2. `modelUsage | to_entries[0]` assumes one model per result; sessions carry several.** `bin/cap-ask:192`, `bin/lib.sh:1068`, `bin/lib.sh:1078`.

`state/ask/0b3a2786-…jsonl`'s result carries two entries: `claude-sonnet-5` (`contextWindow` 1000000) and `claude-haiku-4-5-20251001` (`contextWindow` 200000). Order is JSON insertion order — the order models were first used — not the profile's model.

Failure, when the first-used model is the small one: `usage_write` records `model_id`/`model` for a model the profile never ran, so `cap models`' "seen as" column reports the wrong model; and `ctx_pct` divides by 200000 instead of 1000000, inflating the reading fivefold. Pick the entry matching the profile's model, or the largest `contextWindow`, not entry zero.

**3. `find "$CAP_HOME/state/usage" … -mtime +7 -delete` is dead, and the comment above it states a false premise.** `bin/cap-ask:55-60`.

`bin/cap-statusline:114-122` sweeps the entire `state/usage` directory by file mtime against a 24-hour cutoff, for every `.json` in it, regardless of which process wrote each one. Any wired status line removes cap-ask's records six days before this `find` could. The comment's claim, "bin/cap-statusline's own pruning never runs for one", is true of the *write* and false of the *prune*. `usage_read`'s TTL is 900s anyway, so nothing older than 15 minutes is read. Per `rules/code.md`: remove dead code and ceremony without active value. The two `state/ask*` prunes are genuine and should stay.

**4. `usage_write` publishes a fabricated 0% reading when a rate-limit event lacks `unifiedWindows`.** `bin/cap-ask:167`, `bin/lib.sh:1083-1086`.

The call sits before the session-limit check, so it also runs on the rejection turn. If that event omits `unifiedWindows`, the `// 0` defaults write `pct: 0, resets_at: 0` for both windows. `usage_read` (`bin/lib.sh:976`) takes `max_by(.at)`, so this record — the newest — becomes the fleet's reading and reports `0 0 snapshot`: the account reads as empty at the moment it is exhausted. Every captured event here is `status: "allowed"` and does carry `unifiedWindows`, so the trigger shape is unverified; the structure is not. It is also the inverse of the fail-safe the same diff argues for in `ctx_pct` ("unsure reads as full"). Write nothing rather than zeros when the windows are absent.

**5. `docs/pipeline-notes.md:88-89` and `bin/cap-ask:173-175` both state `blocking_limit` was never observed directly. It was.** `state/ask/723a6856-9552-4e44-98b0-b2820e4e2a10.jsonl` in this worktree is a real rejection carrying `terminal_reason: "blocking_limit"` **and** `api_error_status: 429` together — the same class of on-box evidence the note cites two sentences earlier for the other two fields. Failure: a reader weights the signal as speculative, and the next person re-derives evidence already on disk.

## Minor

A few of the new comments restate the code they sit on, which `rules/comments.md` forbids: `bin/cap-ask:124` ("Working directory set via cd, not a flag.") and `:160-161`.

## Verified working

`api_error_status` and `terminal_reason` are real result-event field names (confirmed against captured `result` keys), so the 429 detection at `:177` is sound. `usage_write`'s `utilization * 100` matches the status line's `used_percentage` scale (both produced 69 within the same minute). The `-p --output-format stream-json --verbose` plumbing, per-turn temp files, `errors` extraction, and the codex `exec --output-last-message` path all behave as described. Dropping `tail -15` from `gate_verdict` is justified now that the report holds only the model's answer.

GATE: FAIL
