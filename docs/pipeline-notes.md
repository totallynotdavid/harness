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

on the loser, which crashes Gate A before it produces any output — Gate B still runs fine
since codex resolves trust differently (already had the correct skip-if-trusted guard).
This is now fixed: `harness_trust` checks `.projects[$dir].hasTrustDialogAccepted` first
and skips the read-modify-write entirely when already trusted, matching the pattern the
codex branch already used. If you see the error above again, that fix regressed — check
`bin/lib.sh`'s `harness_trust` claude branch.

**Symptom to recognize:** a `cap gate` batch run in parallel where one task's `gate-A.md`
is empty or missing while its `gate-B.md` looks normal, and the raw log shows the `mv`
error above. Fix: just re-run `cap gate <slug>` for the affected task alone; the others in
the batch are unaffected.

## Stale-base false positives after a sibling task lands (auto-fixed)

When several tasks are spawned from the same base and one of them lands into the shared
base branch while its siblings are still in flight, the siblings' diff against base now
also contains the landed sibling's feature. Gate B (codex/luna) reliably misread this as
"this branch deletes/reverts that feature" — Gate A (sonnet) usually traced it correctly
via `git log`/`git show`, but not always, and either way it wasted a full review cycle on
noise.

`cap gate` now calls `sync_base()` (`bin/lib.sh`) before reviewing, which merges the
worktree onto the base branch's current tip first — silently, when it can do so cleanly
(stash any uncommitted work, merge, reapply the stash). This eliminates the false-positive
class entirely for the common case instead of relying on a gate noticing it.

It is deliberately conservative about the uncommon case: if the merge itself conflicts, or
the stash reapply conflicts, it does **not** try to resolve anything — it reports via
`warn` and either gates the stale diff as-is (merge conflict) or refuses to gate at all,
returning failure (stash-reapply conflict, since that leaves the worktree in a state no
review should run against). `cap gate` treats that refusal as fatal for the run.

**If you hit the stash-reapply-conflict case by hand** (e.g. investigating why a gate
refused to run): the conflict is almost always two independent, non-overlapping additions
landing in the same spot (e.g. two new test functions inserted at the same line), not a
real logic conflict. **Do not hand-resolve it yourself with Edit/Write** — the hub-write
guard blocks direct edits to worktree files for a reason (agents own their worktrees, not
the captain). If a manual `git stash pop` attempt leaves a conflict, `git reset --hard
HEAD` (after confirming the stash still holds the real work via `git stash list`) puts the
worktree back to the clean merge commit; then send the task's agent the conflict location
and let it run `git stash pop` and resolve it itself.
