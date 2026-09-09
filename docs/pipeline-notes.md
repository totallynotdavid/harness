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

## Recognizing the Claude Pro session limit (auto-detected)

A claude-harness (sonnet Gate A, or any opus/`--heavy` spawn) call can silently produce
empty or truncated output when the account is out of quota. In the raw session log this is
a synthetic, zero-token `rate_limit`/429 rejection the CLI injects, not the model getting
cut off mid-response. So the useful question is always what the *previous real turn*
contained, never the rejection text itself. Checked against every session-limit hit
recorded this project so far: none had reached a real conclusion before the rejection,
each was still mid-investigation. Don't assume that generalizes forever, but it means
discarding rather than trying to salvage the truncated turn has been the right call so far.

`cap ask`/`cap gate`'s Gate A now detect this directly: look for `hit your session limit`
in the raw output rather than eyeballing it. When detected, `cap-ask` fails loudly with a
distinct message instead of returning the truncated text as if it were a real result. See
the next section for what it also does with the interrupted session.

This is a real, separate constraint from system memory pressure. Don't misdiagnose it as
an OOM/race issue (both can produce similarly confusing partial output). It affects only
the claude harness; codex/luna (gpt-5.6-luna, the `rival` profile) is unaffected and can
keep working normally while claude-harness work is blocked.

## Resuming a `cap-ask` call after it hits the session limit

`cap-ask` (claude harness only) records the session id and the pane's reported
context-usage percentage to `state/ask-resume/<hash of profile+dir+prompt>.json` when it
detects the rejection above. The **next** `cap-ask` call with the identical (profile, dir,
prompt), i.e. a genuine retry of the same review, which is exactly what re-running
`cap gate <slug>` after the reset time produces, picks this up automatically:

- Recorded context usage **under 30%**: resumes the session directly
  (`claude --resume <id>` with a generic "continue where you left off" prompt). Cheap
  enough that no special handling is needed.
- Recorded context usage **at or above 30%**: does **not** auto-resume by default (a large
  session costs more per turn to continue than a fresh one costs to re-derive). Starts
  fresh instead, and clears the stale record. Set `CAP_ASK_RESUME=force` to resume it
  anyway. When forced, it *always* sends `/compact` as a first turn before the real
  continuation prompt, never resumes a large session uncompacted. This is a deliberate,
  explicit captain-level override, not a heuristic the script guesses at: use it when the
  interrupted work was itself substantial (e.g. a long implementation review) and
  re-deriving that understanding from scratch would cost more than compacting it once.

This only applies to `cap-ask` (i.e. `cap gate`, and any other one-shot `cap ask` call),
because those calls always close their pane afterward. There is no live process left to
just wait on. It does not apply to `cap spawn`/`cap send` ship-task agents: their pane
stays open across a limit hit, so sending a message after the reset time continues the
same still-running process with zero context loss, which is already the right behavior
and needs no special handling.

## Gate A frequency: cheap by default, expensive only when it matters

`cap gate <slug>` now runs Gate B (role `gate-b`, cheap) only, by default. Gate A (role
`gate-a`, a cold fresh session every call) runs only with `cap gate <slug> --full`. Use `--full` for the first review of a task and for the pass right before
landing. Use the plain, B-only form for every intermediate fix-verify round.

This came from watching one task (`rqueue-role-model`) go through 6 recorded fix-verify
rounds, all attributed to Gate B findings in `status.log`, while Gate A ran in lockstep
every round anyway, each time paying for a full cold sonnet session to re-review a diff it
had already found nothing wrong with. Gate A still catches real things B misses (that is
why `--full` exists and matters before landing), but paying that cost on every intermediate
round bought nothing most of the time.

## Verify directly before spending a gate round

`cap verify <slug>` runs the task's own test/lint/typecheck commands (read from its
`mise.toml` or `package.json`, not hardcoded) directly against the worktree, no model
session involved. Use it to answer "is this specific fix actually there" before either
sending another `cap send` round or spending a `cap gate` call on the same question - a
fresh review session re-deriving "does this test pass" from scratch costs a full session
for an answer a deterministic command already gives for free. It complements gate, it does
not replace it: passing tests do not by themselves rule out the logic/security classes of
defect gate exists to catch.

## Ready-to-land is now tracked, not inferred

`cap gate` records each profile's verdict in `state/tasks/<slug>/gate.json`, tagged with a
fingerprint of exactly what was reviewed (`git diff <base>` plus any uncommitted change).
`cap crew` reads that file: a task whose agent reports `done` shows as `ready` instead only
when **both** A and B last passed **at the fingerprint the tree has right now** - a stale
pass (code changed since), a FAIL, or a profile that never ran at all all fall back to
plain `done`. This exists because `done` alone was indistinguishable from "still needs
another round": one task went through 6+ fix-verify rounds, each one reported `done`, and
none of them ever got `cap commit`/`cap land` run against it. `ready` in `cap crew` is the
signal that was missing - see it, land it, don't start another round on it.

`cap send <slug> "<text>"` injects text into an *already-running* agent pane. The agent
keeps its accumulated session context, so sending another round of findings costs only
what that round's reasoning costs, not a cold re-read of the whole task. Prefer it over
dropping and respawning a task whenever the existing agent can pick up where it left off.
Only `cap drop` + fresh `cap spawn` when the task's direction has fundamentally changed
(e.g. redoing the brief) or the worktree is in a state not worth preserving.

## Orphaned panes and processes from killed background calls

When the harness kills a `run_in_background` Bash call (e.g. for memory pressure), the
process it started is not always killed with it. It can keep running as an orphan. This
has been observed as duplicate leftover `claude --model sonnet` review processes still
consuming memory well after the call that started them was reported killed. Periodically
check `ps aux --sort=-%mem | grep -E "claude|codex"` for duplicates and `herdr pane list`
for panes with `"agent_status":"unknown"` sitting in a task's worktree (a leftover shell
with no tracked agent, from a call that crashed or never got its `herdr pane close`).
`kill -9` genuine orphaned processes; `herdr pane close <pane_id>` empty leftover panes.

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
  status line and records the reading; every session Captain starts renders it, so the
  fleet keeps it fresh for free. Wire it up once in `~/.claude/settings.json`:
  `"statusLine": { "type": "command", "command": "<captain>/bin/cap-statusline" }`.
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
ask for and cannot act on. Resolutions append to `state/usage/dispatch.log` with the command
that asked; `cap budget` reads them back. Warnings that change what the captain does next, a
gate that did not complete or a tier naming a profile that does not exist, still go to
stderr.
