Outcome: the captain session gets notified that a `cap spawn`-dispatched agent finished
without needing the user to type a new prompt first. Paper cut #3 (`cap papercut add
watch ...`) names the symptom: the captain repeatedly has to be told "check progress" and
run `cap peek`/`cap agents` manually, discovering only then that a task already went idle
minutes earlier.

Root cause already identified this session, verify it rather than re-deriving it: `cap
spawn` launches each agent in its own tmux pane (`bin/cap-spawn`) as an independent OS
process — it is not a Claude Code "background task" the harness's own task-notification
system tracks (that system only watches things started via the harness's own Bash
`run_in_background` or Agent tool calls). The only existing signal path is
`bin/hooks/task-status.sh`, which is a `UserPromptSubmit` hook — read it, it only runs
(and only reports "Waiting on you: ...") when the user submits a new prompt. That is pull,
gated on user action, not push. So a finished agent can sit idle for an arbitrary amount
of time with nothing telling the captain, until the user happens to prompt again.

Confirm this diagnosis is actually correct (read `bin/cap-spawn`, `bin/hooks/task-status.sh`,
`bin/cap-watch`, and `docs/architecture.md`/`docs/operations.md` for how task state and
session ownership are modeled) before proposing a fix — don't assume the summary above is
complete or that there isn't a second reporting path already partially built.

Constraints (from the standing rule this repo is built around — read
`.claude/projects/-home-dubu-git-captain/memory/determinism-by-design-not-memory.md`... no,
read the actual pinned note in this repo's own `CLAUDE.md`/`AGENTS.md` for the phrasing):
the fix must be a mechanism, not a reminder. "Write a note telling future captains to run
`cap watch` in the background" is not acceptable — the captain should not need to know this
problem exists or remember a workaround. The fix has to make the notification happen by
construction.

Explore concretely (this is genuinely open, don't force a specific answer):

- Can `cap spawn` itself kick off something the *invoking* Claude Code session's own
  background-task tracking picks up — e.g. launching a small watcher (`cap watch <slug>`
  or a poll loop) via a mechanism equivalent to Bash `run_in_background`, so the harness's
  native notification fires when that watcher detects the task going idle/done? This session
  cannot invoke its own tools from a spawned script, so figure out whether `cap spawn` can
  hand back something the captain session's own turn can hook into (e.g. print a suggested
  companion command, or — better — whether Captain has any existing convention for this;
  check if `cap watch` was ever meant to be run this way given its own `--timeout`/`--interval`
  flags).
- Alternative: a lighter-weight signal outside Claude Code's tracking entirely, e.g. a
  desktop notification (`notify-send` or equivalent) or writing to a location the captain's
  *next* tool call would naturally touch sooner (this would only reduce latency, not solve
  push-vs-pull, so weigh it honestly against the real fix).
- If a real push mechanism is not achievable given how `cap spawn`/tmux panes work, say so
  plainly and explain the actual constraint (e.g. "Claude Code's task-notification system
  has no public hook for external processes") rather than forcing a fix that only looks like
  one.

Evidence: a description of the actual mechanism you landed on (or a clear "not achievable,
here is why" with the constraint named precisely), plus, if you did implement something,
a real demonstration — spawn a throwaway task against a scratch project (or this repo, if
you can safely simulate task completion) and show the captain actually gets notified without
a new prompt being typed. Leave any code change uncommitted as usual; this is captain's own
repo (project "captain"), so the same "agents leave changes uncommitted, captain delivers"
rule applies here too.
