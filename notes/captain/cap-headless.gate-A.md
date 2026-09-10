Gates pass (`mise run lint`, `check:andlist`, `check:syntax` all rc=0) and the happy path works live: `./bin/cap-ask haiku "Say the single word: alpha"` printed `alpha`, and `cap budget` read the reading `usage_write` had just left (`5h 14%, 7d 35%, read 6s ago`). The defects are below.

## 1. Landing a task destroys its gate reports (`bin/cap-gate:29,62`)

`out_dir` moved from `$CAP_HOME/notes/$CAP_PROJECT` to `$TASKS/$slug`, which is `state/tasks/<slug>/`. `state/` is in `.gitignore`, and `bin/cap-land:185` runs `cap-drop "$slug" --force`, whose line 51 is `rm -rf "$(task_dir "$slug")"`.

Failure: the documented delivery path (`cap check` → `cap cleanup` → `cap commit` → `cap land`) now deletes `gate-A.md` and `gate-B.md` at the moment the work lands. Every accepted task loses the review that accepted it. Before this change the reports were tracked files — `paper-cuts.md:21` records recovering a zero-byte `local-env.gate-A.md` *from git*, which is no longer possible. The 12 reports already tracked under `notes/` (`notes/classroom/local-env.gate-A.md` and others) are now orphaned: `cap gate` will never rewrite them, so they stay permanently stale next to the real ones. This also contradicts `docs/architecture.md:19` (`| Notes and reports | notes/<project>/ |`) and is outside the brief, which said not to change output a human reads.

## 2. A dead session wedges the retry path permanently (`bin/cap-ask:196-200`)

The resume record is deleted only on the success path (line 200) and in the `>=30%` branch (line 100). The `is_error` die at line 196 exits first, so the record survives.

Verified failure: `claude -p --output-format stream-json --verbose --resume <unknown-id>` exits 1 and emits a fresh result event with `is_error: true`, `subtype: "error_during_execution"`, `errors: ["No conversation found with session ID: ..."]`. So once a record exists (written on a session limit) and its session becomes unresumable — the worktree was dropped, or claude pruned the transcript — every subsequent `cap gate <slug>` on that same fingerprint matches the record, resumes the dead id, dies at line 197, and leaves the record in place. `cap-gate` warns "did not run to completion", records nothing, and exits 2 forever. No review ever runs again until someone deletes `state/ask-resume/*.json` by hand. Master self-healed here: it printed the pane text and exited 0, which reached the unconditional `rm -f "$resume_file"`.

## 3. The result and rate-limit events are read from the previous run (`bin/cap-ask:137-142,157-168`)

`$jsonl` is opened with `>>` and, on the resume path (line 116), is the *previous* run's file. Both `result_json` and `rl_json` are then `tail -1` over the whole accumulated file, so nothing scopes them to this run's turn.

Failure: a resumed turn that dies without emitting its own result event (the low-memory guard killing a backgrounded `cap gate` is recorded in `paper-cuts.md:34`) leaves `result_json` = the previous run's session-limit result and `rl_json` = its `status: "rejected"` event. Line 174 then sees `is_error=true` plus `rl_status=rejected`, calls `profile_block` with the *old* `resetsAt`, and rewrites the resume record — reporting a session limit that did not happen this run. That is the same bug `docs/pipeline-notes.md` describes for master's stale scrollback banner, reintroduced through the file instead of the screen. Separately, `usage_write` at line 167 stamps that stale reading with `at: $(now)`, and `usage_read` picks the newest `at`, so tier sizing runs on an old quota number.

The `CAP_ASK_RESUME=force` path is worse: turn 1 is `/compact`, turn 2 is the real prompt. If turn 2 dies without a result, `result_json` is turn 1's `/compact` result with `is_error=false`, so cap-ask prints the compaction output as the answer and exits 0. `cap-cleanup:29` and `cap-commit:33` consume that answer directly.

The fix is per-turn scoping: record `wc -c <"$jsonl"` before each turn and read only past that offset, or give each turn its own file.

## 4. Session-limit detection has no evidence and ignores `subtype` (`bin/cap-ask:148,174`)

The prose match on `hit your session limit` was removed and replaced with `rl_status = rejected || api_error_status = 429 || terminal_reason = blocking_limit`. `subtype` is extracted at line 148 and used only in the error message, never in the test, although the brief named it as a detection signal. Nothing in the diff or the repo shows a captured result event from an actual session limit, so it is unverified which of these three fields the harness sets.

Failure if none is set: `session_limit` stays 0, cap-ask dies with the generic error at line 197, `profile_block` is never called and no resume record is written. The tier keeps dispatching to an exhausted profile, which is exactly what `profile_block` exists to prevent.

## 5. The reason for a failure is thrown away (`bin/cap-ask:137,197`)

The harness call sends stderr to `/dev/null` and the die message reports only `subtype`/`terminal_reason`/`api_error_status`. The result event carries `errors: [...]` with the actual text (verified above) and it is never read. An operator gets `subtype error_during_execution, terminal_reason unknown, api_error_status none` and has to open the JSONL to learn "No conversation found with session ID".

## 6. Stale text describing a pane that is gone

- `bin/cap-ask:193`: "output above is truncated, not a real result" — headless cap-ask prints nothing before this die, so there is no output above. `cap-gate`'s `tee` receives an empty file.
- `bin/lib.sh:557`: "never the prompt or a pane's chrome" defends the whole-file scan by naming a pane cap-ask no longer opens. `rules/comments.md:13` — state the current contract.
- `docs/pipeline-notes.md:84-85` still documents `state/ask-resume/<hash of profile+dir+prompt>.json` and "the pane's reported context-usage percentage". Records are now named by session id and the percentage is computed from `usage`/`contextWindow`. `CLAUDE.md` tells agents to read this file before running gate rounds.

## 7. Minor

- `bin/lib.sh:33`: the `python3` fallback in `new_uuid` is unreachable by the comment's own reasoning ("uuidgen is not guaranteed present; the kernel's own generator is") and adds an undeclared dependency. `rules/code.md`: remove ceremony without active value.
- `bin/lib.sh:1051`: `usage_write` takes eight positional arguments and writes `cwd` and `project_dir` from the same one. Callers have to remember the order of four unlabelled numbers.
- `state/ask/*.jsonl` grows without bound (7–23 KB per call, carrying full review text); nothing prunes it, unlike `dispatch_log`. The resume scan at `bin/cap-ask:77-85` now forks a `jq` per record file on every claude ask.
- `bin/cap-ask:236`: `printf '%s\n' "$(cat "$last_msg")"` where `cat "$last_msg"` does the same thing.

GATE: FAIL
