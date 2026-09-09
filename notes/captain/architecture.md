# The shape Captain should have

Written after a day that produced sixteen distinct failures across one project
rebuild. Every number below was measured on this machine, not estimated.

## The thesis

Captain is not a collection of commands. It is a set of gates around one
lifecycle, and a rule only exists if it is attached to a transition that can
refuse.

Everything that went wrong today went wrong because a rule was written down
somewhere instead of being attached to something. `rules/commits.md` has said
"never add a Co-Authored-By trailer" since the repository began. Five trailers
were written anyway, by agents that had been told to read it. The count went to
zero the same hour `cap land` started exiting non-zero on them. Same rule, same
file, same repository. The difference was an exit code.

## 1. Where a policy lives

A policy sits in exactly one of six layers. The architectural rule is that it
belongs in the highest layer that can hold it, and that a policy sitting in
layer 5 or 6 is an open bug against the harness rather than a solution.

| layer | mechanism | travels on clone | can be ignored | context cost |
| --- | --- | --- | --- | --- |
| 1 impossible | a hook blocks the tool call | yes | no | none until it fires |
| 2 refused | a command exits non-zero | yes | no | none until it fires |
| 3 provided | the work is already done, no choice arises | yes | no | none |
| 4 delivered | generated per-task scaffolding (`contract.md`) | yes | yes | one task |
| 5 documented | repository prose (`AGENTS.md`, `rules/`) | yes | yes | every session |
| 6 remembered | `~/.claude` memory | **no** | yes | every session |

Layer 6 is the one to retire first. It does not survive `git clone` to a VPS,
which makes it the only layer that fails for a reason nothing in the repository
can fix. Layer 5 travels but costs every agent's context on every session to
prevent something layers 1 through 3 can remove outright.

The practical consequence is that `rules/` should carry an enforcement column.
A rule whose header names `bin/cap-land` is a rule nobody has to trust a model
about. A rule with no named enforcer is the backlog.

## 2. The lifecycle is the spine

Every gate belongs to a transition. A rule with no transition is prose.

```
  plan  ->  spawn  ->  work  ->  verify  ->  review  ->  land  ->  drop
```

| transition | gate | state today |
| --- | --- | --- |
| plan | ownership globs are disjoint and cover the tree | missing |
| spawn | memory available exceeds the project's measured peak | partial |
| spawn | no live task owns an intersecting path | missing |
| spawn | two or more tasks require a base that passes `cap verify` | missing |
| spawn | dependencies installed, declared tools present | missing |
| work | writes outside the task's owned paths are blocked | missing |
| verify | the project's own tooling, no model session | done |
| review | one command per task at a time | done for gate only |
| review | a report is replaced only by a report with a verdict | done |
| review | rounds on one task are bounded | missing |
| land | the branch shares an ancestor with its base | missing |
| land | the trial merge is clean | done |
| land | commit summaries and trailers obey `rules/commits.md` | done |
| drop | landing a task releases its pane | missing |

## 3. The wave is the missing unit

`cap spawn` takes one slug. A collision is not a property of any one task, it is
a property of the set. A single-task command therefore cannot see one, which is
why four agents each wrote their own `package.json`, `vitest.config.ts`,
`.env.example` and `pnpm-lock.yaml`, and why `shared/grade-to-words.ts` was
written twice.

The unit of dispatch should be the wave.

    state/waves/<name>.tsv     slug, owned globs, brief, base

- `cap wave check` refuses when two rows intersect, or when the union leaves a
  path in the tree unowned. Partitioning the tree is the plan, so the command
  that refuses an overlapping partition is the command that forces the planning.
- `cap wave spawn` starts the rows, bounded by capacity, queueing the rest.
- Landing needs no integration step, because with disjoint ownership the merges
  are fast-forwards by construction.

The integration task that had to resolve four fractures by hand, and then
reported done while the suite was broken, existed only because the partition was
never written down.

Ownership needs two enforcers, not one. `cap wave check` prevents the overlap
from being created. A `PreToolUse` hook in the worktree, the same shape as
`guard-hub-writes.sh`, prevents an agent from writing outside its globs. The
second is what makes the repository root unwritable to a slice, which is the
whole point: dependencies must be settled in the foundation, before the fan-out.

## 4. Capacity is a measurement, not a constant

`CAP_MIN_FREE_MB` is currently a guess. The harness can do better because it
already runs the builds.

A `nuxt build` that takes seventeen seconds with memory free ran for three hours
and eighteen minutes under swap exhaustion, holding 772 MB the entire time and
deepening the pressure that caused it. Parallelism is faster right up to the
point the working set stops fitting, and then it inverts.

Record observed peak RSS per project, and let a wave admit
`floor(available / peak)` tasks at a time. For aula that is 475 MB for the test
suite and roughly 772 MB for a build, which on this box is four or five
concurrent tasks, not nine.

The same measurement settles the question that started this. On a machine with
memory free the aula suite runs 98 tests in 2.93 seconds with file parallelism
on, and 6.74 seconds with it off, at an identical 475 MB peak either way.
Serializing the suite is 2.3 times slower for nothing. The timeouts that
prompted it were the thrash cascade, not a configuration problem.

## 5. Provisioning: detect the command, declare the tools

Sixteen of sixty-nine failing tool calls were an agent discovering that its
worktree lacked something obvious. `cap spawn` runs `git worktree add` and
starts the pane immediately, so a worktree has no `node_modules` at all.

These are two problems and they need opposite mechanisms.

**The install command must be detected, never assumed.** Five checked-out
repositories give five different answers, and `culqi360` needs three at once
(`mise.toml`, `bun.lock`, `Cargo.lock`). `cap verify` already solves exactly
this: it reads mise tasks, falls back to `package.json` scripts, and picks the
package manager from the lockfile. Preflight should reuse that ladder, extended
to `bun.lock`, `uv.lock`, `poetry.lock`, `Cargo.lock`, `go.sum`, `Gemfile.lock`
and `composer.lock`. When nothing is recognised it should do nothing and say
nothing. Best effort, never a refusal, because a harness that refuses to spawn
on four of five projects is worse than the gap it closes.

**The tool list must be declared, and it belongs in Captain.** Nothing in a
repository states that it needs `pdfinfo`. Detection cannot recover that. The
list therefore lives in Captain's own config, not in the target repository,
because Captain is the thing that gets cloned to the VPS and because most of the
registered projects are clones nobody should be restructuring. `mise` installs
what its registry covers, which includes podman, php, gh, jq, node and pnpm. A
shell line covers the rest. The list should grow one row at a time as agents hit
gaps, never be authored upfront for fifty-seven projects.

The caches need no help at all. The pnpm store is 445 MB and the Playwright
browsers are 658 MB, both machine-global already, and a warm install into a
fresh worktree takes 10.4 seconds against 2 percent disk usage. Captain's only
obligation is to avoid breaking that, by never pointing a project at a
per-worktree store. Sharing a single `node_modules` between worktrees would
undo it: two tasks can carry different lockfiles, so one task's install would
mutate another's tree mid-run, which is the collision class of section 3
relocated somewhere much harder to see than a merge conflict.

What preflight actually buys is not bytes and not seconds. It is turns. Five
further failures were not missing packages at all, they were agents running
scratch scripts from the session scratchpad, outside the worktree, where node
cannot resolve `node_modules`.

## 6. What travels and what does not

Cloning Captain to another machine is the test that separates the two kinds of
state, and getting the boundary wrong has already cost a file.

- Repository state travels: `config/`, `rules/`, `notes/`, `cases/`, `bin/`.
- Machine state does not: `state/tasks/`, panes, worktrees under `CAP_WORK_ROOT`.

`cap map` violates this. It regenerates `map.md`, a tracked file, from a
local disk scan, so running it on a machine holding a subset of the projects
deletes every row for repositories checked out elsewhere. It cut the table from
seventeen rows to one. The fix follows from the boundary rather than from
taste: `config/projects.tsv` is repository state and travels, `map.md` is
machine state and should be generated and ignored.

The same boundary retires layer 6. The four memories that shape a Captain
session today are injected from `~/.claude` and are not in `AGENTS.md`. Clone
this repository to a VPS and a fresh session starts without them, including the
one that says to prefer design over memory.

## 7. Captain should be subject to its own gates

Captain has no tests, no `mise.toml`, and is not registered as a project against
itself. Two shell defects surfaced today that its own gates would have caught.

- `[ cond ] && cmd` as a bare statement aborts the script under `set -e`
  whenever the condition is false. It has bitten twice for real, and fifty more
  matches across `bin/` have never been audited.
- `local slug=$1 dir=$TASKS/$slug` fails under `set -u`, because `local` expands
  every word before it assigns any of them.

`shellcheck` plus `bash -n` over `bin/`, run by `cap verify` on Captain itself,
closes both classes. A harness that enforces discipline should be the first
thing subject to it.

## 8. Sequencing

The ordering is by leverage, measured against what actually failed.

1. **Ownership and the wave.** Removes the collision class and deletes the
   integration step. Most of today's damage descends from its absence.
2. **The fan-out gate.** Two or more tasks may not branch from a base that fails
   `cap verify`. One task from a broken base is fine, that is the task fixing
   it. This encodes foundation-first without a sentence of prose, because the
   only way to reach a verified base is to have built one.
3. **Preflight, detection half.** Cheap, and mostly reuses `cap verify`.
4. **Capacity from measurement**, replacing the constant.
5. **Finish the locking.** `task_lock` guards `cap gate` only; `check`,
   `commit`, `land` and `drop` share the same state.
6. **Ancestry and lifecycle.** Refuse a land with no merge base. Release the
   pane when a task lands.
7. **The tool list**, growing one row at a time.
8. **Captain in its own pipeline.**

## What already exists

Recorded so the ledger stays honest. Landed today: the commit-hygiene gate, the
trial-merge precheck, the collision warning in `cap check`, the memory refusal
in `cap spawn`, `task_lock` in `cap gate`, atomic gate reports, `cap sessions`,
and a `UserPromptSubmit` hook that names what is waiting rather than making the
captain ask. Thirteen of the sixty-nine failures were guards correctly blocking
an agent, so the layer-1 mechanisms that exist are earning their place.
