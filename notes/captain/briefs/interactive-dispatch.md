# One dispatch path: every session is a real session

## The defect

Captain starts agent sessions two ways.

`cap spawn` runs `claude "${margs[@]}" $CAP_AGENT_FLAGS "$kick"` in a herdr pane.
That is an ordinary session: it has a prompt box, the captain can watch it, type
into it, and answer a permission prompt in it.

`cap ask` runs `claude -p --output-format stream-json --verbose`, and
`codex exec --json`. Print mode is a one-shot, non-interactive run. Everything
built on `cap ask` inherits it: `cap gate`, `cap commit`, `cap cleanup`,
`cap skills`.

An earlier round wrapped the print-mode call in a herdr pane (`pane_dispatch`).
That made it visible and left it non-interactive. The pane shows a JSON
firehose. Nobody can steer it, `cap send` cannot reach it, and a permission
prompt inside it hangs unanswered. Visibility was never the goal on its own.

## What the probe established

Measured on 2026-09-11 against the real CLI, not inferred from docs.

- `--output-format` and `--json-schema` work only with `--print`. There is no
  structured-output flag for an interactive session. Any design that keeps the
  structured output as a flag keeps print mode.
- An interactive `claude` launched in a herdr pane is a real session. Its own
  status line carries the model, `ctx N% used`, and the rate-limit windows
  (`5h:14% 7d:1%`) that `cap ask` currently mines from `rate_limit_event`.
- A `Stop` hook injected through `--settings` fires at the end of every turn and
  hands back JSON containing `session_id`, `transcript_path`,
  `last_assistant_message`, `permission_mode`, `effort` and `stop_hook_active`.
- `last_assistant_message` carried a 400-line, 3492-byte answer whole. Gate
  reports are multi-KB, so this was tested deliberately.
- `--session-id <uuid>` is honoured by interactive sessions, so the id and the
  transcript are known before launch.
- The session stays alive at its prompt after a turn ends. A second turn typed
  into the pane ran normally.

The result therefore comes from harness machinery, not from a flag and not from
the agent choosing to cooperate. `cap spawn` already injects a `PreToolUse` hook
through `--settings`, so the mechanism is one Captain uses today.

An earlier proposal in this series was to have the dispatched agent write its
answer to a file. That is rejected: it depends on the agent complying, which is
a memory dressed as a design.

## The shape

One dispatch path, used by `cap spawn` and `cap ask` alike.

1. Open a herdr pane.
2. Launch a real interactive session with `--session-id` chosen up front and
   `--settings` carrying Captain's hooks: the existing task-path guard, plus
   `Stop`.
3. The `Stop` hook writes its payload under the task's own state directory and
   marks the turn done. The dispatcher waits on that, not on process exit.
4. The answer is `last_assistant_message`. Detail and token counts come from
   `transcript_path`. The usage meter reads the session's own status line.
5. The session stays open. `cap send` types into it.

## What this removes

`-p`, `--output-format stream-json`, `--verbose`, `codex exec --json`, the
stream-parsing block in `cap-ask` (`result`, `is_error`, `rate_limit_event`),
`pane_dispatch` as a mechanism separate from `pane_launch`, and `state/ask/`
as a transcript store the harness already maintains.

## What this gains beyond visibility

A gate or commit session can be steered while it runs. A permission prompt makes
herdr report `blocked`, which `task_state` already surfaces; under print mode
the same prompt hangs silently. Multi-turn compact-and-continue stops being a
special case, because the session persists by default.

## Known brittle edges

These are the parts to design rather than discover.

- When a turn's final assistant message is a tool call with no text,
  `last_assistant_message` is empty. The transcript is the fallback.
- The `Stop` hook does not fire when a session is killed. The pane-liveness
  check must stay.
- `stop_hook_active` must be honoured, or a hook that re-prompts will loop.
- Submitting text needs `herdr pane send-keys <pane> enter`. `pane_submit`
  already does this correctly; a flag does not exist.
- Session-limit rejection is read today from the result event. How it surfaces
  in an interactive session was not tested and must not be assumed.
- codex has no `Stop` hook. `--output-last-message` is its answer channel, but
  its turn-end signal has to come from somewhere else. This is the only place
  the two harnesses genuinely diverge, so design it first rather than last.

## A verdict is not a result

A separate defect found in the same series, recorded here because it is the same
kind of mistake. `cap gate` accepted a gate report whose entire content was the
three words `GATE: FAIL`, after a 39-turn, 12-minute review. The guard catches
only `UNKNOWN`. Had the report read `GATE: PASS`, `gate_ready` would have gone
green and the crew hook would have advised landing.

Nothing in the JSON stream distinguished that run from a real review:
`subtype` was `success` and `is_error` was `false`. The check has to live in
Captain whichever dispatch path is used, which is one more reason the stream is
not worth its cost.
