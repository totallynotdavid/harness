# Captain learns there is more than one captain

Every command in `bin/` assumes one captain drives one task at a time. That is
false on this machine and has been for days: three `claude` sessions are sitting
in the hub right now, all with `cwd` of `/home/dubu/git/captain`, and nothing
coordinates them.

`cap sessions` already reports the condition. Read its header comment first — it
names two incidents from 2026-09-09 and says plainly that nothing there is
recorded or tracked. It observes. It does not enforce. That is the gap you are
closing.

Read `notes/captain/plan.md`, stage 2, for the six incidents and the argument.

## What to build

### 1. Session identity, derived rather than stored

Add a helper to `bin/lib.sh` that returns the identity of the session that ran
this `cap` command: walk the process tree from `$$` upward to the first `claude`
or `codex` ancestor and report it. There is no new state file, no id threaded
through any call, and nothing an agent has to cooperate with. This is the same
`/proc` reading `cap sessions` already does, so read that first and reuse its
approach rather than inventing a second one.

A bare pid is not enough on its own, because pids are reused. Make the identity
survive that. `/proc/<pid>/stat` field 22 is the process start time and the
usual way to pin a pid to one incarnation; confirm that yourself rather than
take it from me.

Decide and state what the helper returns when there is no harness ancestor — a
`cap` command run from a plain shell is a real case and must keep working.

### 2. Tasks have an owner

`cap spawn` records the owning session on the task record. `task.env` is the
existing place for it and `task_env_set` already exists.

Every command that mutates a task refuses when the task is owned by a live
session other than the caller. It must say which pid holds it, so the captain
can look. `--take` claims the task explicitly and is the only way past the
refusal.

An owner that is no longer running is not an owner. A task whose owning session
has exited is claimable with no stale lock to clear and no expiry to tune,
because the kernel is the record. This is the property that makes the whole
design safe: work out what has to be true for it to hold, and say so.

Which commands count as mutating is yours to decide from the code, not from a
list I hand you. `cap crew`, `cap watch` and `cap sessions` are read-only and
must stay usable by any session — a captain has to be able to see a task it does
not own. Say which commands you put on each side and why.

### 3. Close the two lock gaps

`cap send` and `cap spawn` take no `task_lock` while `cap check`, `cap cleanup`,
`cap commit`, `cap drop`, `cap gate`, `cap land` and `cap restack` all do. That
asymmetry is how a round got dispatched into a worktree a gate was still
reading, on 2026-09-10: `cap gate` held the lock for a five-minute review and
`cap send` walked straight past it.

Check `cap verify` and `cap wave` too. I have not looked at whether they mutate.

### 4. `gate_fingerprint` must diff against the merge base

`bin/lib.sh`'s `gate_fingerprint` diffs against `$base` — the base branch's
current tip. `diff_base` already exists and `cap-check`, `cap-cleanup` and
`cap-gate`'s review prompt were all moved onto it. This one was missed.

The failure, from 2026-09-10: both gate profiles PASSed at fingerprint
`722eef4b`, a sibling session landed four commits on master during the review,
and `cap gate` then reported NOT ready to land on a branch whose own content had
not changed by a byte. Confirmed at the time — the merge-base fingerprint was
still exactly `722eef4b` while the base-tip one had moved to `0e820283`.

### 5. `status.log` must say who sent each message

Every captain message in a task's `status.log` is recorded as "sent by the
captain". With three captains that line cannot be acted on. Record the sending
session. The agent does not need to see this and should not be told about it;
it is for the captain reading the log afterwards.

The log also truncates each message to a prefix, so a captain cannot read what
another captain asked for even after the fact. That is the half that turned a
collision into a near-revert of someone else's accepted work. Fix it or say why
the truncation has to stay.

## Constraints

Read `rules/code.md`, `rules/comments.md` and `rules/commits.md` before you
start, and keep commit summaries to 50 characters or fewer — `cap land` refuses
the branch otherwise, and finding that out at the end costs a rebuild.

The guard must be unreachable, not advisory. If an agent or a captain can
proceed by ignoring a message, it is not built yet. It should also cost nothing
and say nothing until the moment it fires.

Do not add a `Co-Authored-By` trailer, a session link, or any other AI credit to
any commit.

## Verifying

The real test is two sessions, and you can stage it with two shells rather than
two harnesses if you say how you made the identity differ. At minimum, show:

- a task owned by session A refusing a mutating command from session B, naming A
- `--take` claiming it
- a task whose owner has exited being claimable with no intervention
- `cap send` blocked while `cap gate` holds the lock on the same task
- `gate_fingerprint` unchanged across a commit landing on the base branch, and
  changed by an actual edit in the worktree

`mise run lint`, `check:andlist`, `check:syntax`, `check:verdict`,
`check:usage-shape` and `cap check` must all pass. Do not commit.
