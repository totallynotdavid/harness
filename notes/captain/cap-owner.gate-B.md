Now I have everything I need. Let me summarize what I checked and found.

**What I checked and verified as working:**
- `bash -n` and `shellcheck -S warning` pass clean on every changed file — no syntax errors, no new warnings.
- The custom `trap` override (`bin/lib.sh`) composes correctly for every `trap CMD EXIT` call site in the tree (`cap-map`, `cap-verify`'s `on_exit`, `cap-spawn`'s `cleanup`), verified by tracing `CAP_EXIT_PID`/`CAP_EXIT_FNS` reset/append logic against each call site's ordering relative to `task_lock`.
- `task_try_lock`/`task_unlock`/`task_release` reentrancy (same-process depth counting and cross-process `CAP_LOCKS` inheritance) — traced every call site in `stack_cascade`, `stack_cascade_landed`, `cap-restack --undo`; every acquired lock has exactly one matching release on every exit path, no leaks found.
- `queue_send`/`queue_claim`/`queue_deliver_claimed`/`queue_recover_stranded`/`queue_flush` — traced the claim-before-read, drop-before-attempt, and untrusted-pane invariants; consistent with the design documented in `docs/pipeline-notes.md`.
- `cap_env_scrub` conversion from array to function: all four call sites (`cap-ask`, `cap-spawn`, `cap-send`) correctly updated to `mapfile -t`.
- `cap-commit`'s new AI-trailer-stripping rewrite (`commit-tree`-based): parent remapping through `remap[]`, per-commit sign mirroring via `%G?`, and the post-rewrite `still_bad` safety check are all logically sound for linear and merge histories in the range.
- `task_state`/`task_agent_state` refactor (shared by `cap-crew`, `hooks/crew-status.sh`, `cap-spawn`'s reclaim check) correctly fixes the "stale log verb" bug described in `docs/pipeline-notes.md` by checking herdr's live status before the log.
- `gate_verdict`/`gate_strip_markdown`/`gate_has_evidence` split preserves the original verdict-parsing behavior while adding the new evidence check.

**Defect found:**

`bin/cap-ask:109-123` and `bin/cap-ask:284-292`, via `pane_dispatch` in `bin/lib.sh:879`

`pane_dispatch` opens a herdr pane and, inside it, runs `claude -p --output-format stream-json --verbose` (line 114) and `codex exec --json --output-last-message` (line 288) — i.e., headless print-mode/JSON sessions wrapped in a pane. This is precisely the design the captain rejected and recorded in the pinned memory `crew-must-be-visible.md`: "I treated 'runs in a pane' as the whole requirement and built `pane_dispatch` to put a herdr pane around `claude -p --output-format stream-json --verbose`. That passes the letter of the earlier rule and fails its point... The captain has now rejected that reading directly. Do not reach for it again." The memory also names the concrete failure this causes: the pane shows a JSON firehose, not a session — nobody can steer it, `cap-send` cannot reach it, and (absent the `bypassPermissions`/`--dangerously-bypass-approvals-and-sandbox` flags this repo happens to set) a permission prompt inside it would hang unanswered.

The diff's own `docs/pipeline-notes.md` addition admits this directly: "The sessions `cap-ask` starts are still print mode... A print-mode session cannot be typed into, `cap-send` cannot reach it... Removing print mode is the open work." So this is shipped as a known-incomplete state, reintroducing a pattern the captain explicitly told a prior session not to reach for again.

The `pane_dispatch` polling/done-file machinery itself is sound and is in fact the piece the memory says the fix should reuse ("`pane_dispatch` already polls for a done file, so the waiting machinery exists") — but it's wired to the wrong invocation (`-p`/`--json` print mode) instead of an ordinary interactive session with file-based output, which is what the memory prescribes as the actual replacement.

I checked for concrete crash/data-loss bugs across the full 2361-line diff (lib.sh, all bin/cap-* scripts, the hook, and the two docs/rules files) and found none — the locking, queueing, and ownership machinery is unusually well-reasoned and internally consistent. The one substantive defect is this reintroduction of headless print-mode sessions against explicit, previously-corrected captain policy.

GATE: FAIL
