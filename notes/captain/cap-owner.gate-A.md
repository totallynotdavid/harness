I found three defects that break what the code says it guarantees, plus two smaller issues. One of the three is confirmed live and one is marked plausible. I reviewed all 21 changed files against 862308a; there are no uncommitted changes.

## Defects

**1. A later process types queued messages behind a message that was never confirmed.** (`bin/lib.sh:726-732`, `797-818`)
- The comment on `CAP_QUEUE_UNTRUSTED` names the hazard: text from an unconfirmed `pane_submit` may still be sitting in the input box. Typing more behind it merges the two, and the next Enter submits both.
- The guard only lasts for one process. When `queue_deliver_claimed` fails, the rest of the batch stays in `send-queue.flushing`. The next locking command runs `queue_recover_stranded` and delivers it into the same pane, with no memory that the pane was untrusted.
- `cap send`'s own unconfirmed message has the same problem. The captain's next `cap send` types straight in behind it.
- **Confirmed live.** In a scratch copy, process 1 queued three messages and its submit failed on "msg one". Process 2 then typed "msg two" and "msg three" into the pane. `status.log` shows `unconfirmed: … msg one` followed by `working: … msg two` and `working: … msg three`.
- `docs/pipeline-notes.md` describes this as intended ("stays queued and is tried on the next flush"), which contradicts the comment's reasoning.
- The fix is to keep the untrusted state on disk, not in a process variable.

**2. Undoing a restack in two passes can wipe out new commits.** (`bin/cap-restack:116`, `134`)
- A partial undo now tells the user to "rerun cap restack <slug> --undo to retry them".
- The rerun replays the whole snapshot, including refs the first pass already restored and released. `update-ref "$ref" "$sha"` has no old-value check, and a clean tree gets `reset --hard`.
- **Failure:** the first pass restores child A and skips B because B is locked. A's agent commits more work, which leaves its tree clean. The rerun resets A's branch to the snapshot sha and its new commits disappear from the branch.
- The same loop also locks each snapshot line separately. If contention clears between a child's ref line and its `FIELD CAP_PARENT_TIP` line, the field is restored but the branch is not. The next `cap restack` then runs `rebase --onto` from the wrong base and replays the parent's commits.

**3. The hook shows an old reason for a new prompt.** (`bin/hooks/crew-status.sh:49`)
- When herdr reports `blocked`, the hook prints the latest `^blocked:` line from the whole `status.log`, however old.
- **Failure:** an agent logged `blocked: need DB creds` hours ago and has since moved on. It now sits at a permission prompt, and the hook still says "is blocked: need DB creds". That points the captain at the wrong problem.

**4. Plausible: `pane_submit` can press Enter on a permission prompt.** (`bin/lib.sh:989-1008`)
- It presses Enter up to 3 times, retrying whenever `pane_wait_working` does not see `working`. It does not stop when the status is `blocked`.
- If the first Enter starts a turn that reaches a prompt before the 1-second poll samples `working`, the retry Enter accepts the prompt's default. `pane_usable`'s comment names exactly this risk.
- `queue_deliver_claimed` also checks `pane_usable` only once per batch, not before each message.

**5. Minor: comments that tell history, against `rules/code.md`.**
- `bin/lib.sh:632-637` ("A cwd match on the bare pid alone - dropped from here") describes removed code.
- Several other new comments defend a decision rather than state intent.

## Outside rules/code.md
`cap-ask` still runs `claude -p --output-format stream-json` and `codex exec --json`, now inside a pane (`bin/cap-ask:114`). You have ruled that shape out: no session should run in print mode, visible or not. The docs list its removal as open work.

## Checked and working
- **Lint and syntax:** the `mise.toml` lint command (`shellcheck -S warning`), `bin/lint-andlist`, `bin/lint-gate-verdict` (23 shapes, 4 corpus reports) and `bin/lint-usage-shape` all pass. `bash -n` passes on every script.
- **`trap` wrapper, live:** handlers added before and after a lock both run, in order. Each sees the real exit code (7), which the script keeps. Neither a subshell nor a command substitution re-runs the parent's handlers.
- **Lock depth, live:** taking the same lock twice gives depth 2. One `task_unlock` drops it back to 1 and leaves `CAP_LOCKS` intact.
- **Lock pairing, by reading:** `stack_cascade` and `stack_cascade_landed` pair each lock with exactly one release on every exit. The undo loop does the same.
- **Lock handoff, by reading:**
  - `cap-land` calling `cap-drop` inherits both the lock and the session identity, so ownership passes.
  - `cap-cleanup` no longer uses `exec`, so the exit flush runs.
  - `cap-spawn` checks for an existing task while holding the lock.
  - `cap_env_scrub` runs after locking, so dispatched agents never inherit `CAP_LOCKS` or `CAP_SESSION`.
- **`cap-commit` trailer stripping, by reading:** only commits from the first flagged one onward are rebuilt. Merge parents are kept, the tree is unchanged, and a re-check dies if any attribution survives.
- **The rest, by reading:** `cap-verify --repo` has its own project lock. `gate_ready` does its cheap checks first. Flag parsing rejects unknown flags in land, drop, restack, gate, cleanup, commit and verify.

GATE: FAIL
