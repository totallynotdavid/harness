# One task state, derived from what cannot lie

`state/tasks/<slug>/status.log` records a verb per line, and the agent picks it.
Three captain-facing readers act on that choice:

- `bin/hooks/crew-status.sh:22` surfaces a task on `done`, `blocked`,
  `needs-input` or `failed`, and stays silent otherwise.
- `bin/cap-crew:10` reads the same verb first and only asks herdr afterwards.
- `bin/cap-spawn:136` skips a row unless the verb is exactly `done`.

On 2026-09-11 an agent finished a round and logged it as `working: round 5 done
- ...`. The pane went idle. `cap crew` showed `idle`, because that column comes
from herdr. The hook said nothing, because the verb was `working`. The captain
waited more than ten minutes and had to ask twice before the finished work was
noticed. The hook exists so he never has to ask; it failed on a word.

## The rule to build to

No captain-facing state derives from a word an agent chose. herdr reports
whether a session is running, git reports what is in the worktree, and
`gate.json` reports the verdicts. Those cannot be talked around. The log stays
useful for the *reason* an agent stopped, never for *whether* it stopped.

## What to build

One helper in `bin/lib.sh` that answers "what state is this task in", and the
three readers above all call it instead of reading the verb themselves.
`bin/cap-crew`'s `status_of` is the closest thing to it today, so start there
rather than inventing a second shape.

The inversion that matters: a live pane whose agent is idle is waiting on the
captain, whatever the log says, and a live pane whose agent is working is
working, whatever the log says. The verb is consulted only to name an idle stop
- `blocked`, `needs-input` and `failed` each carry a reason the captain wants to
read, and anything else that has stopped is simply waiting on him.

Decide what the helper returns when herdr reports neither working nor idle, and
say why. `task_idle_age` exists and `bin/cap-crew:41` already falls back to it.

## Constraints

Read `rules/code.md`, `rules/comments.md` and `rules/commits.md`. Keep commit
summaries to 50 characters or fewer and check them yourself before reporting.

Do not add a `Co-Authored-By` trailer, a session link, or any other AI credit.

## Verifying

Show the hook surfacing a task whose last logged verb is `working` and whose
pane has gone idle - that is the exact case that failed. Show it staying silent
while the agent is genuinely working. Show `cap crew` and the hook agreeing on
the same task in both states.

`mise run lint`, `check:andlist`, `check:syntax`, `check:verdict`,
`check:usage-shape` and `cap check` must all pass. Do not commit.
