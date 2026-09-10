Good, those helpers are still used by cap-spawn/cap-send, so keeping them in lib.sh is correct — not dead code. Now let me check the actual logic more carefully, especially the new cap-ask claude branch.
Reviewed `git diff master` across `bin/cap-ask`, `bin/cap-gate`, `bin/lib.sh`, `docs/pipeline-notes.md` against `rules/code.md`. No uncommitted changes on top. `shellcheck -S warning` is clean on all three shell files.

## Findings

**1. `/compact` sent through headless `-p` mode is unverified as a functioning slash command — `bin/cap-ask:112-116`**

The resume flow was rewritten from an interactive `herdr` pane (master's version literally typed `/compact` into a live, open Claude Code REPL, where slash-command handling is a documented interactive feature) to a single-shot `claude -p --output-format stream-json --resume <id> ... "/compact"` call. Nothing in this diff or in `docs/pipeline-notes.md` establishes that print/headless mode parses `/compact` as the built-in compaction command rather than as literal chat text. If it doesn't, the compact turn is a no-op message, `session_args` is then updated to resume that same (uncompacted) session, and the real continuation prompt runs against a session `CAP_ASK_RESUME=force` was specifically supposed to guarantee gets compacted first. `bin/lib.sh`'s own comment and `docs/pipeline-notes.md:115-116` both assert this as an invariant ("always compacts first ... never resume a large session uncompacted"), so a silent no-op here breaks a documented guarantee rather than just degrading gracefully — the failure is spending tokens/context on an uncompacted resume exactly in the case (`>=30%` context) the code exists to avoid. This is the one piece of the rewrite that changed execution context (interactive → headless) for a mechanism that depends on execution context, and I found no evidence in the diff that it was exercised end-to-end.

**2. `usage_write`'s rate-limit field paths are unverified, and default silently to 0% on a miss — `bin/lib.sh:1053-1077`**

`docs/pipeline-notes.md:82-90` states precisely which `result`/`rate_limit_event` fields were confirmed against a real captured rejection: `apiErrorStatus`, `quotaLimits.status`, `terminal_reason`. `usage_write` additionally reads `.rate_limit_info.unifiedWindows.five_hour.utilization` / `.resetsAt` (and the `seven_day` equivalents) to record ordinary (non-rejection) quota readings, and none of these paths are covered by that same verification note. Every accessor uses `// 0`/`// null` jq defaults, so a wrong path doesn't error — it silently writes a `0%`-used reading into `state/usage/<session>.json`. Since `usage_read` folds these files in via `max_by(.at)` and downstream dispatch sizing (`role_profile_or_die`, `dispatch_log`) trusts that number, a wrong field name here doesn't fail loud, it fails by telling the rest of Captain the account has full headroom when it may not — the opposite failure mode from what this function exists to prevent ("cap-ask would fly blind... without this").

Both are reasoning-based risk findings from static review (no CLI available to exercise headless resume/compact or capture a live `rate_limit_event` here) rather than confirmed reproductions — but #1 sits directly on a safety invariant the code text itself asserts, in the part of this diff that changed the most (pane → headless), so I'd want it exercised against a real session before this lands.

GATE: FAIL

---

Captain's check, 2026-09-10. Both findings are wrong.

Finding 1: `claude -p --output-format stream-json --verbose --resume <id> "/compact"`
run against a live session returns `Not enough messages to compact.` as both the
assistant text and the `result`. That is the compactor's own message, not a chat
reply, so `/compact` is a real slash command in print mode and the resume
invariant holds.

Finding 2: a live `rate_limit_event` on this machine carries
`.rate_limit_info.unifiedWindows.five_hour.utilization = 0.4` and
`.resetsAt = 1789057200`, which are the paths `usage_write` reads, with
utilization a 0-1 fraction. Gate A verified the same fields independently in the
same round.

Both were framed as risks for the captain to verify before landing, which moves
the work the gate exists to do back onto the captain.
