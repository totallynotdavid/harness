## Review against fb2db4fa1866e3bea5ad07a6b2b1bba8920ae8b9

Working tree is clean; all changes are the five commits already on the branch (`49af05a`…`27831be`). Reviewed the full diff plus `rules/code.md`.

### 1. `cap-send` can hold the task lock for up to ~25 minutes, blocking every other mutating command on that task

`bin/cap-send:27-28` acquires `task_lock "$slug" "${CAP_SEND_LOCK_WAIT:-900}"` and `task_owner_claim` before doing anything else, and per `task_lock`'s contract (`bin/lib.sh:305-306`, unchanged) the lock is held until the process exits. Before this diff, `cap-send` never touched the lock at all.

If the pane's context is over `CAP_SEND_CTX_MAX`, `cap-send` calls `compact_pane` (`bin/cap-send:132-154`), which polls for up to `CAP_SEND_COMPACT_SECS` (default 600s, `config/captain.conf:118`) — all while still holding the lock it may itself have waited up to 900s (`CAP_SEND_LOCK_WAIT`) to acquire. So a single `cap send` can occupy the task lock for close to 25 minutes.

Every other mutating command (`cap-gate`, `cap-verify`, `cap-commit`, `cap-land`, `cap-cleanup`, `cap-restack`, `cap-drop`) calls `task_lock "$slug"` with the default `wait=0`, which refuses immediately (`bin/lib.sh:312-317`) rather than waiting. So while one captain's `cap send` is compacting a near-full session, a `cap gate`/`cap land`/etc. from anyone else on that same task dies immediately with "already held by pid …", for a duration that has nothing to do with review or delivery. This is a new failure mode the diff introduces, not present before it (`cap-send` was previously lock-free).

The lock should be released (or re-acquired only around the parts of `cap-send` that actually need exclusivity — the `status.log`/ownership write) before entering `compact_pane`'s long poll, not held across it.

### 2. `session_alive` treats an unreadable `/proc` entry the same as "process is dead"

`bin/lib.sh:398-403`:
```
live=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
[ -n "$live" ] && [ "$live" = "$stamp" ]
```
If the `/proc/$pid/stat` read fails for any transient reason (permission, timing, sandboxing), `live` is empty and the function reports "not alive" — the same result as a genuinely dead process. `task_owner_claim` (`bin/lib.sh:415-418`) then silently reclaims ownership without requiring `--take`:
```
if [ -n "$owner" ] && [ "$owner" != "$me" ] && session_alive "$owner"; then
  [ "$take" = 1 ] || die ...
fi
task_env_set "$slug" CAP_OWNER "$me"
```
This is exactly the "two live sessions stomp on each other" scenario the ownership feature (commit `2bac72b`) exists to prevent — conflating "I couldn't confirm liveness" with "confirmed dead" reopens it silently instead of failing loud.

### 3. `session_identity`'s `/proc/[pid]/stat` parsing is fragile, and now backs an access-control decision

`bin/lib.sh:372,378,382,388,401` all split `/proc/$pid/stat` on whitespace with plain `awk '{print $N}'` to read ppid (field 4) and start time (field 22). Field 2 of that file (`comm`) can contain spaces or parentheses (renamed processes, wrapper scripts), which shifts every subsequent field and yields a wrong ppid/start-time silently — a well-known pitfall of parsing this file. The same pattern existed before this diff only in `bin/hooks/crew-status.sh`, where a wrong answer just skewed an advisory nag count. This diff moves it into `lib.sh` and makes it the basis for `task_owner_claim`'s lock/ownership decisions across every mutating `cap-*` command, so a misparse here now risks a wrongful "already owned" refusal or, worse, a wrong session being treated as the same identity as another. Low probability given `claude`/`codex` comm names are unlikely to contain such characters, but the blast radius of a wrong answer changed materially and the code doesn't guard against it (e.g. by stripping `.*)\s*` before field-splitting, the standard fix).

Everything else — the `task_owner_claim`/`--take` wiring across `cap-gate/verify/commit/land/cleanup/restack/drop`, the `cap_env_scrub` function replacing the frozen `CAP_ENV_SCRUB` array at the two call sites that export new `CAP_*` vars mid-process (`cap-spawn`, `cap-send`), the `cap-spawn` lock-before-mkdir race fix, and the `crew-status.sh`/`cap-sessions` simplification — is internally consistent and I could not find a defect in it.

GATE: FAIL
