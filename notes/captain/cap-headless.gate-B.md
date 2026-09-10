  Defects

  1. bin/cap-ask (claude branch, ~lines 130-145): rate-limit reading is not scoped to the current turn, so it can record stale quota data as current.

  jsonl is opened with >> and, on a resumed session, is the same file used by the earlier invocation that hit the session limit
  (jsonl="$CAP_HOME/state/ask/$resume_id.jsonl"). After a turn runs, the code does:

  rl_json=$(jq -c 'select(.type == "rate_limit_event")' "$jsonl" 2>/dev/null | tail -1)

  This scans the entire accumulated file, not just this invocation's output. result events are safe to grab this way because the CLI always emits one at the end of every
  turn, so the freshest one is always last. rate_limit_event is not guaranteed every turn — the surrounding comment itself says quota is read "straight from this run's own
  rate-limit event" specifically because a headless call would otherwise "fly blind between explicit rejections," which only makes sense if the event is emitted
  intermittently.

  Concretely: call 1 hits the session limit and appends a rate_limit_event with status: rejected. A retry resumes the same session, appends to the same jsonl, and succeeds
  (is_error=false) without emitting a fresh rate_limit_event of its own. tail -1 then falls back to call 1's stale rejected event, and usage_write persists that stale
  (likely near-100%, old resetsAt) reading to $CAP_USAGE_DIR/$session_id.json as if it were this run's current quota. That file feeds role_profile_or_die's CAP_ADMIT_*
  checks (per docs/pipeline-notes.md), so a successful retry can leave the account looking exhausted to every later dispatch decision until some other call happens to
  overwrite it. The same staleness can also make the session_limit misclassification (rl_status = rejected) fire against an unrelated real error on a later turn in the same
  file, with a die message reporting an old, already-passed reset time.

  2. paper-cuts.md: a documented unresolved bug was deleted without being fixed.

  The diff removes this entry:

  ▎ "cap cleanup and cap commit run an agent inside a task's worktree with no ownership guard... cap-ask should take the same guard argument cap-spawn builds, whenever it is
  ▎ called with --dir pointing at a task worktree."

  bin/cap-spawn passes --settings "$guard_settings" to install the ownership-guard hook (bin/cap-spawn:301). The rewritten bin/cap-ask claude command (bin/cap-ask:128) still
  builds its args as "${session_args[@]}" "${margs[@]}" $CAP_AGENT_FLAGS "$turn_prompt" — no --settings/guard argument anywhere. bin/cap-cleanup:29 and bin/cap-commit:33
  still dispatch through cap-ask into $CAP_TREE. The exact bug described still reproduces unchanged; only the record of it was deleted. This erases the paper trail for a
  live bug instead of fixing it.

  3. docs/pipeline-notes.md was not updated and now describes a mechanism this diff removed.

  Not touched by the diff, but its "Recognizing the Claude Pro session limit" and "Resuming a cap-ask call" sections describe the pane-scraping design this diff replaces:
  detection by grepping raw output for hit your session limit, and a resume record at state/ask-resume/<hash of profile+dir+prompt>.json. The new code detects rejection from
  structured JSON (rate_limit_event/is_error/api_error_status/terminal_reason) and names resume records by session id, matched by scanning file contents
  (bin/cap-ask:73-90). CLAUDE.md tells every agent to read this doc "before running many cap gate rounds" to avoid known pitfalls; as written it will send the next reader
  looking for text that no longer exists in the pipeline.

  GATE: FAIL

✻ Brewed for 3m 44s · done 6:44 AM

─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Sonnet 5  |  ctx 9% used  91% left  |  in:94962 out:10  |  5h:16% 7d:35%                                                                                              /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · 4 memories recalled · ← for agents
