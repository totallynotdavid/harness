# Pipeline notes

Lessons about running Captain's own pipeline efficiently, found while operating it.
Read this when a task is going through many `cap gate` rounds, when a gate result looks
wrong, or when a background call fails for no obvious reason.

## The `~/.claude.json` trust-file race (fixed, watch for regressions)

`harness_trust()` in `bin/lib.sh` used to rewrite `~/.claude.json` unconditionally on
*every* claude-harness launch (every `cap ask`, every `cap gate` Gate A, every claude/opus
`cap spawn`), not just the first launch for a given worktree. Running several of those in
parallel (e.g. `cap gate` for 4 tasks at once, all using the claude harness) raced on the
same `mv` and produced:

```
mv: cannot create regular file '/home/dubu/.claude.json': File exists
```

on the loser. That crashes Gate A before it produces any output. Gate B still runs fine
since codex resolves trust differently (it already had the correct skip-if-trusted guard).
This is now fixed: `harness_trust` checks `.projects[$dir].hasTrustDialogAccepted` first
and skips the read-modify-write entirely when already trusted, matching the pattern the
codex branch already used. If you see the error above again, that fix regressed. Check
`bin/lib.sh`'s `harness_trust` claude branch.

**Symptom to recognize:** a `cap gate` batch run in parallel where one task's `gate-A.md`
is empty or missing while its `gate-B.md` looks normal, and the raw log shows the `mv`
error above. Fix: just re-run `cap gate <slug>` for the affected task alone; the others in
the batch are unaffected.

## Stale-base false positives after a sibling task lands (auto-fixed)

When several tasks are spawned from the same base and one of them lands into the shared
base branch while its siblings are still in flight, the siblings' diff against base now
also contains the landed sibling's feature. Gate B (codex/luna) reliably misread this as
"this branch deletes/reverts that feature." Gate A (sonnet) usually traced it correctly
via `git log`/`git show`, but not always, and either way it wasted a full review cycle on
noise.

`cap gate` now calls `sync_base()` (`bin/lib.sh`) before reviewing, which merges the
worktree onto the base branch's current tip first, silently, when it can do so cleanly
(stash any uncommitted work, merge, reapply the stash). This eliminates the false-positive
class entirely for the common case instead of relying on a gate noticing it.

It is deliberately conservative about the uncommon case: if the merge itself conflicts, or
the stash reapply conflicts, it does **not** try to resolve anything. It reports via
`warn` and either gates the stale diff as-is (merge conflict) or refuses to gate at all,
returning failure (stash-reapply conflict, since that leaves the worktree in a state no
review should run against). `cap gate` treats that refusal as fatal for the run.

**If you hit the stash-reapply-conflict case by hand** (e.g. investigating why a gate
refused to run): the conflict is almost always two independent, non-overlapping additions
landing in the same spot (e.g. two new test functions inserted at the same line), not a
real logic conflict. **Do not hand-resolve it yourself with Edit/Write.** The hub-write
guard blocks direct edits to worktree files for a reason: agents own their worktrees, not
the captain. If a manual `git stash pop` attempt leaves a conflict, `git reset --hard
HEAD` (after confirming the stash still holds the real work via `git stash list`) puts the
worktree back to the clean merge commit. Then send the task's agent the conflict location
and let it run `git stash pop` and resolve it itself.

`sync_base()`'s merge is a point-in-time fix: it clears the drift that exists the moment
`cap gate` runs, but a sibling landing into base afterward reopens the same gap before the
next round. A gate reviewing `git diff <base's current tip>` directly can still show a
change nobody on this branch made. `gate_fingerprint` and the reviewer's own `git diff`
command both go through `diff_base()` (`bin/lib.sh`) instead, which diffs against
`merge-base(base, HEAD)` - the point where this branch actually left base - the same fix
`bin/cap-check` already applies as `diff_from`. Confirmed live: a `paper-cuts.md` entry
added to master after a branch was cut showed as that branch deleting it under
`git diff master`, and was empty under `git diff $(git merge-base master HEAD)`.

## Recognizing the Claude Pro session limit (auto-detected)

A claude-harness (sonnet Gate A, or any opus/`--heavy` spawn) call can silently produce
empty or truncated output when the account is out of quota. In the raw session log this is
a synthetic, zero-token `rate_limit`/429 rejection the CLI injects, not the model getting
cut off mid-response. So the useful question is always what the *previous real turn*
contained, never the rejection text itself. Checked against every session-limit hit
recorded this project so far: none had reached a real conclusion before the rejection,
each was still mid-investigation. Don't assume that generalizes forever, but it means
discarding rather than trying to salvage the truncated turn has been the right call so far.

Every `cap ask` session is an interactive session whose turns end through a hook
(`bin/caplib.py`). A claude turn the account refuses ends through the `StopFailure` hook
with `error: "rate_limit"`, and `cap ask` reads that field, never the rendered text. Any
other `StopFailure` error (`model_not_found` was seen live) is reported as a harness error,
not a limit. A codex turn that fails runs no hook at all; its rollout records a
`task_complete` event carrying an `error`, and `cap ask` reads that, then asks
`codex_limit_reached` whether the failure was the account. Either way it fails loudly
instead of returning partial text as a result.

This is a real, separate constraint from system memory pressure. Don't misdiagnose it as
an OOM/race issue (both can produce similarly confusing partial output). It affects only
the claude harness; codex/luna (gpt-5.6-luna, the `rival` profile) is unaffected and can
keep working normally while claude-harness work is blocked.

## Resuming a `cap-ask` call after it hits the session limit

On a claude session limit, `cap ask` records the session id and its context percentage
(`ctx_pct`, which the session's own status line wrote to `state/usage/<session>.json`) in
`state/ask-resume/<key>.json`. The key hashes the profile, worktree, prompt, and
`CAP_ASK_KEY`; `cap gate` passes its diff fingerprint there, so a record never resumes
against different code. A missing reading counts as 100%.

The next identical call resumes the recorded session (`claude --resume <id>` with a
"continue where you left off" prompt) when it was under 30% context. At or above 30% it
starts fresh and leaves the record, and `CAP_ASK_RESUME=force` resumes it anyway. The
session is interactive, so compaction is the harness's own business once resumed. A clean
answer clears the record; records and dispatch directories older than seven days are pruned.

This does not apply to `cap spawn` agents: their session stays open across a limit, and a
`cap send` after the reset continues it.

## Gate A frequency: cheap by default, expensive only when it matters

`cap gate <slug>` now runs Gate B (role `gate-b`, cheap) only, by default. Gate A (role
`gate-a`, a cold fresh session every call) runs only with `cap gate <slug> --full`. Use `--full` for the first review of a task and for the pass right before
landing. Use the plain, B-only form for every intermediate fix-verify round.

This came from watching one task (`rqueue-role-model`) go through 6 recorded fix-verify
rounds, all attributed to Gate B findings in `status.log`, while Gate A ran in lockstep
every round anyway, each time paying for a full cold sonnet session to re-review a diff it
had already found nothing wrong with. Gate A still catches real things B misses (that is
why `--full` exists and matters before landing), but paying that cost on every intermediate
round bought nothing most of the time. A full round reuses a profile's PASS when its
fingerprint still matches the complete diff, so requesting the final review does not
repeat identical work.

## Verify directly before spending a gate round

`cap verify <slug>` runs the task's own test/lint/typecheck commands (read from its
`mise.toml` or `package.json`, not hardcoded) directly against the worktree, no model
session involved. Use it to answer "is this specific fix actually there" before either
sending another `cap send` round or spending a `cap gate` call on the same question - a
fresh review session re-deriving "does this test pass" from scratch costs a full session
for an answer a deterministic command already gives for free. It complements gate, it does
not replace it: passing tests do not by themselves rule out the logic/security classes of
defect gate exists to catch.

Each check's stdout and stderr first go to a regular log file, then `cap verify` copies
that completed log to its own stdout. A detached service can keep the log open, but it
cannot keep a caller's pipe open after `cap verify` exits. `cap doctor --remote HOST`
asks the other host to resolve its Captain checkout from `CAP_HOME` or `cap` on its
PATH, with `--path` for an explicit location, before comparing the two reports.

The local doctor also keeps `~/.local/bin/cap` linked to the checkout and adds that
directory to `~/.profile` when the profile does not already mention it. `bin/mise-doctor`
is the repository-facing setup check behind `mise run doctor`; the built-in `mise doctor`
remains the host-level diagnostic.

## Task state is not a log word

On 2026-09-11 `bin/hooks/crew-status.sh` stayed silent for ten minutes on a task that had
gone idle, because the last thing its agent logged was `working: round 5 done - ...` - the
wrong verb, picked by the agent, and the hook only reacts to `done`, `blocked`,
`needs-input`, `failed`. `cap crew` showed `idle` for the same task at the same time (that
column reads herdr, not the log). Two readers of the same state disagreeing, because one of
them trusted a word an agent typed instead of asking whether it was actually true.

`task_state` (`bin/lib.sh`) is the one place that question gets answered now. `bin/cap-crew`,
`bin/hooks/crew-status.sh`, and `bin/cap-spawn`'s reclaimable-task check all call it instead
of reading `task_status_latest` themselves. Ground truth only: herdr says whether
the agent is running - that answer is never talked around by a log line claiming otherwise -
`gate.json` says whether the work is ready to land (see below), and the log is read only to
name *why* a task stopped, and only for `blocked`, `needs-input`, and `failed`, the three
verbs that carry a reason. A bare `done`, or nothing logged at all, is not a reason: it falls
through to `ready` when `gate.json` says so, and otherwise to `idle` (still live, stopped,
nothing to report) or `exited` (pane gone). herdr itself answering neither `working` nor
`idle` falls back to whether the pane's visible output has changed recently
(`task_state_stale_age`), tracked in its own file so this poll never eats the
change-edge `task_idle_age` and `cap-watch` depend on.

`cap gate` records each profile's verdict in `state/tasks/<slug>/gate.json`, tagged with a
fingerprint of exactly what was reviewed (`git diff <base>` plus any uncommitted change).
`task_state` reads that file directly: a stopped task shows `ready` only when **both** A and
B last passed **at the fingerprint the tree has right now** - a stale pass (code changed
since), a FAIL, or a profile that never ran at all all fall back to `idle`/`exited` instead.
This exists because `done` alone was indistinguishable from "still needs another round": one
task went through 6+ fix-verify rounds, each one reported `done`, and none of them ever got
`cap commit`/`cap land` run against it. `ready` is the signal that was missing - see it, land
it, don't start another round on it.

`cap send <slug> "<text>"` injects text into an *already-running* agent pane. The agent
keeps its accumulated session context, so sending another round of findings costs only
what that round's reasoning costs, not a cold re-read of the whole task. Prefer it over
dropping and respawning a task whenever the existing agent can pick up where it left off.
Only `cap drop` + fresh `cap spawn` when the task's direction has fundamentally changed
(e.g. redoing the brief) or the worktree is in a state not worth preserving.

## cap-send and the task lock

Delivering into a worktree `cap gate` is mid-rebase (`sync_base`) is unsafe, so `cap send`
has to respect the same lock `cap gate`, `cap verify`, `cap cleanup`, `cap commit`, and
`cap land` take for their whole run. Two designs were tried and rejected before the current
one:

A bounded wait (`flock -w`) cannot work at any bound: `cap verify` loops its own
`CAP_VERIFY_MAX` ceiling over every script it runs, so it can hold the lock for roughly an
hour; `cap gate`'s review waits on its reviewers' turns, bounded only by `CAP_ASK_MAX_WAIT`
(3600s by default) - well past the timeout (commonly 600s) of any tool a captain drives
`cap` through, so that tool kills the wait before a bound matching either ceiling ever
resolves, losing the message with no sign it happened.

Holding the lock across the whole command, including `compact_pane`'s wait for the agent's
own context to shrink (up to `CAP_SEND_COMPACT_SECS`, 600s by default), is also wrong: that
step has nothing to do with the worktree, so it has no business holding the same lock every
other command dies against at once.

`cap send` now holds the lock only around the actual delivery (`task_try_lock`, never
blocking) and does the ctx check and any compaction beforehand, unlocked. When the lock is
free, delivery happens exactly as before. When it is not, the message is appended to
`state/tasks/<slug>/send-queue` (`queue_send`) and the command returns at once - it is never
refused, and the captain never has to retype it.

Flushing that queue (`queue_flush`) went through two more designs before landing. Running it
inside `task_try_lock` itself meant `cap gate`'s review and the stack-cascade rebase also
typed the pending message into the agent's pane the moment either happened to acquire the
lock first, mid-review or mid-rebase. Moving the flush into `cap send` alone fixed that but
opened a different gap: a message queued while `cap gate` or `cap land` held the lock then
sat until someone happened to run `cap send` on that task again - nothing else would ever
deliver it, and nothing surfaced that it was waiting.

The queue now flushes on the lock's *release*, for every locking command, not just `cap
send`. `task_try_lock` arms one `EXIT` trap the first time a process locks anything
(`task_flush_locks_on_exit`), and that trap composes with whatever `trap ... EXIT` the
command sets afterwards (`bin/cap-spawn`, `bin/cap-verify`) rather than being overwritten by
it - see the `trap` wrapper above `task_lock` in `bin/lib.sh`. A gate review or a rebase now
flushes the moment it finishes and exits, after its own work is done, never mid-review or
mid-rebase. `cap send` additionally flushes explicitly before its own message, so an older
queued correction still lands ahead of a newer one instead of racing the exit-time flush.

If a holder is killed instead of exiting cleanly, its `EXIT` trap never runs, so its flush
does not happen - but the flock it held still releases at the kernel level as it always has,
so this costs nothing beyond a delay: the message waits for whichever later command locks
that task and exits cleanly, the same as it would if nothing had died. `cap send` reports
this precisely (`queued for <slug>: busy (...); delivered once whoever holds it exits
cleanly`) rather than naming a specific command, since the holder that finally releases the
lock is not always the one holding it when the message was queued.

A kill before the flush starts and a kill *during* it are different failures, and both now
cost only that same delay. `queue_flush` claims its batch by renaming `send-queue` to
`send-queue.flushing` before reading it; a holder killed after that rename but before
delivery finishes left that file behind, unread by anything. `queue_flush` now checks for a
leftover `.flushing` file on every call and folds it back in front of the live queue before
claiming again, so the next flush - by any locking command - picks the backlog up rather than
leaving it orphaned.

Delivery from the queue goes through `pane_submit`, one confirmed attempt - typing the text
in and checking a turn actually started - not a bare `pane_send` trusted to have worked. A
message that fails to confirm is logged to `status.log` as unconfirmed and dropped from the
queue, not retried: `pane_submit` may already have typed it in, and a retry would type it a
second time, merging with whatever it left sitting unsent in the input box. That risk
outlives the process that hit it, so the pane is marked untrusted with a marker on disk
beside the queue (`queue_mark_untrusted`/`queue_untrusted`), not a variable - every later
`queue_flush`, by any command, in any process, refuses that pane outright. Anything still
queued behind the failed message, never typed at all, waits there until the marker clears,
which only happens when `cap send` revives a dead pane: a new pane has a new input box.
Queued text is stored base64-encoded rather than flattened with `tr '\n' ' '`, so a
multi-line message arrives exactly as typed whether the lock happened to be free or not.

## Every agent session runs in a pane

`cap spawn`, `cap send`'s revive, and `cap ask` (and so `cap gate`, `cap commit`,
`cap cleanup`) all start a session the same way (`bin/cap-launch`, `launch` in
`bin/caplib.py`): a real interactive session in a herdr pane, with Captain's hooks passed
on its command line. claude gets them through `--settings`, codex through `-c hooks.*`,
with the hook trust codex asks for seeded in `~/.codex/config.toml` so no launch stops on
a review prompt.

A turn ends when the harness runs `bin/hooks/session-event.sh turn`, which drops the turn's
payload into the directory the dispatcher chose. The answer is the payload's
`last_assistant_message`, or the transcript's last text when the turn ended on a tool call.
The dispatcher also watches the pane: a closed pane, an exited session, or a harness that
goes idle without ending its turn is reported rather than waited out. A permission prompt
shows as `blocked`, is named once on stderr, and can be answered in the pane.

Stopping a dispatcher (Ctrl-C, or a signal to `cap ask` or `cap-review`) closes the panes
it opened. `cap-gate` also records the reviewer's pid and durable result path. If its own
wrapper is killed after the reviewers finish, the next run adopts that result; if it finds
an incomplete review, it reaps the process and its panes before starting again. A reviewer
can be watched and typed into while it runs.

`cap send` revives a dead task by starting the harness with a fixed opening instruction and
typing the captain's actual message through the pane. The message is kept in a private
temporary file only until it has been typed, so source excerpts and findings do not appear
in the harness command line.

Foreground `cap check`, `cap commit`, and `cap gate` write a completion record when they
exit. The reminder hook claims each record once and reports its command and exit status on
the next captain prompt, which gives a backgrounded command the same completion signal as
a stopped crew pane.

## Dispatch sizing: quota routes work, it does not cheapen it

Captain used to name a model at every dispatch site (`CAP_AGENT_MODEL`, `CAP_GATE_A`, and
so on). That is a description of one account on one day, wrong for a different plan and
wrong for the same plan six hours later.

Every dispatch now names a role. A role belongs to a capability tier and never leaves it:

| tier | what it is for | peers |
| --- | --- | --- |
| `heavy` | judgment that has to be right the first time | `opus`, `terra` |
| `standard` | follows a brief, writes code, reviews code | `sonnet`, `terra` |
| `cheap` | breadth, and narrow well-specified work: commits, comment cleanup, lookups | `haiku`, `luna` |

`crew`, `scout` and `gate-b` are `standard`. `gate-a` is `heavy`. `chore`, which is
`cap cleanup` and `cap commit`, is `cheap`.

`scout` is `standard` and not `cheap`, even though scouting is exploration, because what a
Captain scout returns is a judgment the captain plans from. `notes/classroom/rebuild-scope.md`
sized a rebuild, moved where the risk sits, and found a delete guarded by a read capability.
Breadth that returns findings rather than judgments is what `cheap` is for, and
`cap spawn --light` asks for it by name.

Cheap is also not the obvious choice for work that is merely long. Measured from this
repository's own gate reports, Haiku 4.5 ran a review at 19% of its window on 37,090 input
tokens and Sonnet 5 ran one at 10% on 95,086, which puts the windows at roughly 195k and
951k. The cheap tier is about five times smaller. For a genuinely context-exhaustive pass
the binding constraint is the window, not the price.

The peers inside a tier are interchangeable in capability and deliberately live on
different accounts. That is where quota acts: when the claude window fills, `standard` work
moves to `terra` on the codex account, at the same capability. It does not move to `haiku`.
A smaller model is not a cheaper version of the same agent, it is a different agent that
makes different decisions, and a bad decision is paid for twice: once for the session that
made it, again for the rounds that find and undo it.

Quota gets exactly two powers. It chooses which account runs the work, and it decides
whether the work starts at all. `CAP_ADMIT_*` is the utilization above which a tier stops
being admitted: 88 for heavy, 92 for standard, 97 for cheap. A crew agent runs for hours,
so one started at 95% dies mid-task; a short cheap call can safely use what is left. When
no peer is admissible, `cap spawn` and `cap gate` refuse and name the earliest time
capacity returns. Refusing is the correct answer. The gap below 100 is also the headroom
the captain's own session runs on.

`--heavy` raises the tier and `--light` lowers it. Both move the tier rather than bypassing
the sizing, because starting a heavy agent on an exhausted account is the failure this
exists to prevent, and a breadth pass should still queue behind a full account rather than
crash into it. `-m <model>` is the escape hatch that skips sizing entirely, for a captain
who means to spend it anyway.

### The ceiling

Tiers stop at `opus` on claude and `terra` on codex. `cap models` shows the account reaches
further than that: `fable`, `astra` and `sol` are registered as profiles and belong to no
tier. A model stronger than the work needs is not free. It is slower, it spends a window
every other role shares, and Captain would be spending it on the captain's behalf without
being asked. Above the ceiling is a decision made at the call site: `cap ask astra`,
`cap spawn -m fable`.

That ceiling has a price, and it is visible under load. With the claude account full,
`gate-a` (heavy) and `gate-b` (standard) both fall through to `terra`, and `cap gate` says
so rather than reporting two reviews when one model produced both. Adding `astra` to the
heavy tier would separate them again, at the cost of the ceiling. Waiting for the window is
usually cheaper.

### Where the numbers come from

Two measurements, no settings that describe the account:

- The rate-limit windows the harness reports. `bin/cap-statusline` prints Claude Code's
  status line and records the reading for every *interactive* session Captain starts, so
  the fleet keeps it fresh for free. Wire it up once in `~/.claude/settings.json`:
  `"statusLine": { "type": "command", "command": "<captain>/bin/cap-statusline" }`. Every
  session Captain dispatches is given the same status line on its command line, so a
  dispatched session records its reading, and its own context percentage, whatever the
  user's settings say.
- Session-limit rejections. `cap ask` writes the profile to
  `state/usage/blocked/<profile>` until the reported reset, which takes it out of its tier.

Without a status line reading Captain reports `unmeasured` and admits everything. That is
the deliberate failure mode: an unreadable meter is a reason to stop holding back, not a
reason to stop working. `~/.claude.json` caches a reading too and is used as a fallback,
but it was 25 hours stale and reporting 3% while the live windows were at 70%.

Readings are per harness. An Anthropic window says nothing about an OpenAI one.

Codex is read differently because it has no status line hook. It writes the same
information to disk anyway: every turn appends a `token_count` event to its rollout under
`~/.codex/sessions/`, carrying `rate_limits.primary` (the 300-minute window) and
`.secondary` (the 10080-minute one), each with `used_percent` and `resets_at`. Captain
reads the newest rollout. A window whose `resets_at` has passed counts as empty, not full,
which matters more for a rollout than for a status line rewritten every few seconds. Codex
reports exhaustion as a field rather than a sentence, `rate_limits.rate_limit_reached_type`,
and `cap ask` blocks the profile on it.

That record also carries `plan_type`. Captain does not read it, and should not. Reading the
percentage measures the account. Reading the plan describes it, and the description is the
part that goes stale.

There is no inferred ceiling. An earlier version capped dispatch at the model the captain's
own session was running, which guessed at what an account can afford; a rejection answers
the same question from evidence, and a captain who runs haiku to save quota should still be
able to dispatch a real reviewer.

Sizing decisions are not announced. A captain running `cap spawn` is an agent with a context
window, and routine "role crew -> sonnet" chatter spends it on something the reader did not
ask for and cannot act on. Resolutions append to `state/usage/dispatch.jsonl` with the
command that asked, and every finished dispatch appends what it cost there too: exact tokens
from its transcript, and the account's 5h window before and after, labelled account-wide
because anything else running at the time moves it as well. `cap budget` reads both back. Warnings that change what the captain does next, a
gate that did not complete or a tier naming a profile that does not exist, still go to
stderr.

## A related-defect cluster is one task, not several gated separately

On 2026-09-11 through 2026-09-13, hardening Captain's own task locking, ownership handoff,
and `cap-send` queue flush went through 125 gate-a/gate-b rounds over two days, all at
standard tier (`crew` on sonnet). The commits from that window are a long chain of narrow
fixes to the same subsystem: `Fix lock discipline`, `Distinguish live and usable when
queuing`, `Report partial undo when some refs were locked or owned`, `Preserve exit status
in trap handlers`. Each fix closed the one edge case its gate round found and exposed the
next one at a boundary the fix did not cover, because each round saw only its own diff.

A later task covering the same class of defect (dispatcher hardening, task resource
cleanup, gate review state) shipped twelve clean commits in under two hours with almost no
rework, run as one wide-scope task at heavy tier (`crew` on opus) instead of Captain's
default of one small task per defect. The tier change alone does not explain the
difference: a stronger model asked to fix the same defect in the same narrow, one-diff-at-
a-time shape would still only produce a better version of the same narrow fix, and would
still miss the interaction with the next defect over. Seeing the related defects together
in one dispatch is what let the fix address the subsystem instead of one symptom at a time.

When several open defects or paper cuts touch the same subsystem, especially anything
touching shared concurrent state such as locks, ownership, or a message queue, bundle them
into one task before dispatching it, and size that task at heavy tier. Splitting related
work into Captain's default shape of small, separately gated tasks is the wrong shape for
this class of defect regardless of which model runs each one.
