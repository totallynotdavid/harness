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

## `cap send` is cheap; `cap spawn` is not

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
