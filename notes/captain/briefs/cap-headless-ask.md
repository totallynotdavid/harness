# cap ask goes headless

## Why

`bin/cap-ask` launches an interactive TUI in a herdr pane and then reads the
agent's answer off the screen. Of the nineteen paper cuts whose subject is
Captain, six are that decision failing, and none of them failed loudly. Each
produced a confident wrong answer:

- `herdr pane read` defaulted to the visible viewport, so two real gate reviews
  lost findings 1-5 while keeping the verdict and cost line. The reports looked
  complete.
- `gate_verdict` took a fixed `tail -15`, so a genuine `GATE: PASS` below a
  dozen blank lines was recorded as UNKNOWN.
- A resumed session restated a finished verdict about code it had never read,
  because the resume key was a hash of the prompt and the prompt is identical
  every round.
- The session-limit check had to be scoped with `grep -n '^❯ .'` to the text
  after the last prompt line, because a resumed session's scrollback still
  carries the old rejection banner.
- Context percent is scraped with `grep -oE 'ctx [0-9]+% used'`.
- The reset time is scraped with `grep -oE 'resets [^·]*\(UTC\)'`.

Roughly ninety of that file's 227 lines are comments explaining workarounds for
reading a terminal.

None of this is necessary. Both harnesses have a headless mode with a structured
event stream, and every value Captain currently scrapes is a field in it.

## What is already confirmed

Verified directly against the installed CLIs on this box, not from memory.

`claude -p --output-format stream-json --verbose --session-id <uuid> --model haiku "..."`
emits JSONL. The final `{"type":"result"}` event carries:

| field | replaces |
| --- | --- |
| `result` | the whole pane capture, `--lines 1000`, the `^❯` anchor |
| `is_error`, `subtype`, `terminal_reason`, `stop_reason` | guessing from output |
| `session_id` | `herdr agent get ... .agent_session.value` after the fact |
| `usage.*` and `modelUsage.<model>.contextWindow` | `grep -oE 'ctx [0-9]+% used'` |
| `total_cost_usd` | nothing; Captain cannot currently price a dispatch |
| `permission_denials[]` | nothing |

A separate `{"type":"rate_limit_event"}` event carries
`rate_limit_info.unifiedWindows.five_hour.utilization` and `.resetsAt`, plus
`seven_day`. A real reading from this box was `five_hour 0.81, seven_day 0.30`.

`--session-id` is settable before launch, and `--resume <id>` continues the
session. Confirmed: a second call with `--resume` answered a question about
the first call's own reply.

`codex exec --json` prints JSONL events. It also has `--output-schema <FILE>`,
a JSON Schema for the model's final response, and `-o/--output-last-message
<FILE>`.

## What to build

Rewrite `bin/cap-ask` so it runs the harness headless and returns a structured
result. Keep its command-line interface exactly as it is: every caller
(`cap gate`, `cap cleanup`, `cap commit`, the captain by hand) must keep working
unchanged.

1. **claude**: `-p --output-format stream-json --verbose`, with a `--session-id`
   Captain generates before launch. Stream events to
   `state/ask/<id>.jsonl`. Take the answer from the `result` event's `result`
   field.
2. **codex**: `codex exec --json`. Take the answer from its own final event or
   from `--output-last-message`.
3. **Quota**: read `rate_limit_event` and record the same reading
   `usage_read`/`usage_write` already store, so `cap budget` keeps working and
   gets fresher numbers for free. Do not delete `bin/cap-statusline` in this
   task; make it redundant, and say so in your report.
4. **Session limit**: detect it from `is_error`/`subtype`/`api_error_status`
   and the rate-limit event, not from matching `hit your session limit` in
   prose. Keep `profile_block` and the existing tier behaviour.
5. **Resume**: key the pending-session record on the real `session_id` Captain
   chose, not on `sha256(profile, dir, prompt, CAP_ASK_KEY)`. `CAP_ASK_KEY` may
   then be unnecessary; if it is, remove it and update `bin/cap-gate`'s call.
   Keep the under-30%-context policy and `CAP_ASK_RESUME=force`.
6. **`cap gate`**: `gate_verdict` must stop taking a window of lines. Read the
   verdict from the structured result cap-ask now returns. Keep the fingerprint
   behaviour in `gate_record`/`gate_ready` exactly as it is.

Delete the workarounds that become dead: the viewport comment, the `^❯` prompt
anchor, the `ctx`/`resets` greps, the here-string-versus-SIGPIPE note where it
no longer applies. Do not leave them as commented history.

## What not to do

- Do not touch `cap spawn`'s long-running agents. They stay in panes on
  purpose: the captain watches and types at them. This task is one-shot calls
  only, which already close their pane and have no reason to be interactive.
- Do not change any command's flags, output shape a human reads, or
  `config/captain.conf`.
- Do not add a dependency. `jq` is already required.
- Do not remove `require_herdr` from files you are not otherwise changing.

## Verifying

The project's own gates must pass: `mise run lint`, `mise run check:andlist`,
`mise run check:syntax`.

Then prove the real thing, not a scratch script:

1. `cap ask haiku "Say the single word: alpha"` returns `alpha` and nothing
   else. Show the command and its output.
2. A long answer survives intact. Ask for something over 200 lines and confirm
   the first line is present in the returned text. This is the exact failure
   that lost findings 1-5 of two gate reviews.
3. `cap budget` still prints a claude reading, and the reading moved after
   step 1 ran.
4. `cap gate` records a verdict end to end on a real task. Use a worktree that
   already exists rather than spawning one.

Report what each check printed. A claim without its output is not evidence.
