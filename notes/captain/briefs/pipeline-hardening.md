# Harden the gate and land pipeline before building on it

Four independent changes. Land them in any order, each as its own commit.

## 1. Three checks for defect classes the gates keep re-finding

`bin/lint-andlist` is the shape to follow: one mechanical signature, wired
into `mise`, failing before a gate is dispatched. Each of these has already
cost a review round on `cap-owner`.

- A `while ... done < <(cmd)` whose producer can fail invisibly. Zero
  iterations reads exactly like a clean result, so a guard built this way
  reports clean when it could not run. Six sites in `bin/`.
- `git rev-list --reverse` used to order a rewrite without `--topo-order`. It
  emits a side branch before the commit it forked from, so a parent lookup
  built in traversal order is incomplete whenever a merge is in range.
- A flag parsed into a variable that some branch never reads, so the flag is
  accepted and silently dropped.

## 2. Scope `git_dirty`'s untracked count to what it is checking

`git_dirty` (`bin/lib.sh`) is `git status --porcelain | wc -l`, counting
untracked files. `cap-land` calls it twice: once on a task's own worktree,
where an untracked file is real uncommitted work and must block, and once on
the captain hub (`bin/cap-land:66`, `bin/lib.sh:1490`), which several
sessions share with no locking. One session's draft note anywhere in the hub
then blocks every other session's land, and the blocked session cannot tell
whose file it is. Hit landing `cap-owner`: seven untracked paths from three
sessions (`paper-cuts.md`, 2026-09-13).

A merge aborts before touching anything if it would overwrite an untracked
file, so the hub-tree check only needs tracked changes. Give the hub-tree
call sites a tracked-only check; leave the task-tree call sites as they are.

## 3. Register the task-state regression check

`bin/cap-crew` and `bin/hooks/crew-status.sh` now derive whether a task has
stopped from herdr (`task_state`/`task_agent_state` in `bin/lib.sh`), never
from the verb an agent wrote to `status.log`. Add a `check:` task to
`mise.toml` that fails if either file goes back to reading `status.log` as
the sole evidence a task is still running, so the regression `paper-cuts.md`
(2026-09-11) describes cannot silently return.

## 4. Gate the increment, not the whole branch

`cap gate` reviews `CAP_BASE..HEAD` every round. On a task at round 24 that
was 70 commits and 21 files re-reviewed from scratch, including machinery
that passed unchanged two rounds earlier.

`gate.json` already stores a per-profile fingerprint. Store the commit each
profile last returned PASS at, and review from there instead of from the
base. `cap gate --full` keeps the whole-branch review, and `cap land`
requires a `--full` verdict, so nothing lands on an increment-only review.

## Verifying

`mise run lint`, `check:andlist`, `check:syntax`, `check:verdict`,
`check:usage-shape` and `cap check` must all pass.

Show the two new checks catching the exact shape they target, and staying
silent on the current tree. Show a hub with only untracked files in it
passing the dirty check while a hub with a tracked modification still fails
it. Show `cap gate --full` still reviewing the whole branch after an
increment-only round has passed.

## Constraints

Read `rules/code.md`, `rules/comments.md` and `rules/commits.md`. Do not add
a `Co-Authored-By` trailer, a session link, or any other AI credit.
