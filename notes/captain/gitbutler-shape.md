# Shape: GitButler for stacked PRs, PRs, or commits

## 0. Does this fire

Yes. More than one plausible mechanism (adopt GitButler at some depth, or extend the
existing `git`+`gh` path), and getting it wrong means either reopening a load-bearing
isolation guarantee or taking on a dependency Captain doesn't need.

## 1. Requirements

- **R1 — worktree isolation stays real.** No two concurrent agents ever share a working
  directory. **known.** `docs/concepts.md` and `CLAUDE.md` state this as deliberate:
  "This prevents agents from changing Captain or inheriting its `CLAUDE.md`." `cap-spawn`
  implements it with plain `git worktree add`.
- **R2 — git mechanics stay captain-side.** Agents never see PR/commit/merge concerns in
  their brief or instructions. **known.** `docs/concepts.md`: "Agents write code. Captain
  handles commits, delivery, and cleanup." `cap-spawn`'s contract text: "The captain
  handles staging, commits, pushes, pull requests, and merges after review." `cap-commit`
  dispatches a *separate* agent for staging, on purpose, so the implementer's context
  never carries commit-shape concerns either.
- **R3 — fully scriptable, no TTY prompts.** `cap land`/`cap commit` run unattended from
  bash, sometimes chained after `cap watch`. **known.** Current implementation (`git`,
  `gh pr create --fill`, `gh pr merge --squash`) takes zero interactive input.
- **R4 — no new auth/dependency surface.** Captain depends on `git` and `gh`, both already
  authenticated as the same GitHub identity. **known** as a cost to weigh, not a fact to
  spike.
- **R5 — solves a real, current stacking need** (task B built on task A's unlanded branch,
  kept in sync as A changes). **spike**, resolved below.

## 2. Spikes

- **R5: does this repo have a documented stacking need today?**
  `grep -niE "stack|gitbutler|butler|multiple pr|depend" paper-cuts.md NORTH.md README.md`
  → zero hits. `cap spawn` already accepts `--base <branch>`, so chaining a task on an
  unlanded branch is one flag away today; nothing in `state/tasks/`, `paper-cuts.md`, or
  prior commits shows this flag has ever been used that way, or that a captain has been
  blocked by its absence. **Resolved in the negative**: no evidence of a live need. Stated
  as a decision, not a guess — overridable if you have a specific case in mind.

- **What GitButler actually is, and whether it fits worktree-per-task.**
  Read `gitbutlerapp/gitbutler-docs`: `overview.mdx`, `butler-flow.mdx`,
  `workspace-branch.mdx`, `commands/but-worktree.mdx`, `commands/but-pr.mdx`,
  `commands/but-land.mdx`, `commands/but-agent.mdx`, plus the main repo's license.
  Findings:
  - GitButler's entire reason to exist is "work on several branches at the same time...
    in a single working directory" via a `gitbutler/workspace` branch that unions the
    applied branches. That's the exact problem Captain already solved a different way —
    with real `git worktree`s, one per task. Captain isn't the target user this tool was
    built for.
  - `but worktree` does create real, separate directories ("Remove a worktree from disk,
    like `git worktree remove`"), so isolation *can* survive at that layer. But
    `but land --whole-stack` and stacked `but pr` explicitly require "an active GitButler
    workspace... within `but open` mode" — stacking and landing are workspace-scoped
    operations. The docs never say two independent `but worktree` directories can each
    carry their own independent stack; the natural reading is one shared workspace per
    repo clone. That reopens R1 for exactly the tasks you'd stack.
  - `but pr` is not fully non-interactive by default (prompts to pick a branch, confirm
    review creation) and needs `but config forge auth` — a second credential path next to
    the `gh auth` Captain already relies on. Partial R3, fails R4.
  - `but agent` is a setup wizard whose stated job is "writing workflow steering
    instructions into supported agent instruction files" — it exists specifically to put
    git-stacking awareness into the coding agent's own context. That is the opposite of
    R2: Captain deliberately keeps agents git-blind so the implementer's attention never
    splits toward commit shape or PR structure.
  - License: Fair Source, converts to MIT after 2 years per release; free to use today.
    Not a blocker, but it's a product with its own roadmap and hosted auth flow, not a
    static protocol like `git`.

## 3. Shapes

- **A — Do nothing.** Keep `git worktree` + `gh pr create`/`gh pr merge`. Costs: no
  stacking automation. Forecloses: nothing; fully reversible later.
- **B — Adopt GitButler wholesale.** Replace worktree-per-task with one GitButler
  workspace per project; tasks become virtual branches; `cap land` calls `but pr` /
  `but land --whole-stack`; agents get `but agent`-steered instructions. Costs: gives up
  R1 and R2 outright, adds a second CLI and auth path, `but pr` isn't prompt-free.
  Forecloses: the isolation guarantee as currently designed.
- **C — Narrow adoption.** Add an opt-in `cap spawn --stack <parent-slug>` that keeps
  using `git worktree` but shells to `but pr`/`but land --whole-stack` only for landing a
  chained task. Costs: two landing code paths, still pulls in `but` + forge auth, and
  R1/R2 are *unresolved* rather than satisfied — the docs don't confirm stacked
  `but worktree`s stay independent. Forecloses: keeping the dependency graph at "just git
  and gh."
- **D — Extend the existing path.** Teach `task.env` a `CAP_PARENT=<slug>`, have
  `cap land` use `gh pr create --base <parent-branch>` when a parent is recorded, and add
  a small `cap restack <slug>` that runs `git rebase` against the parent's current tip.
  No new binary, no new auth, isolation untouched because it's still literally
  `git worktree add`. Costs: Captain builds and owns this sliver of logic instead of
  reusing a maintained product; no TUI, no fancy conflict-resolution UX.

## 4. The cross

| | A | B | C | D |
|---|---|---|---|---|
| R1 isolation preserved | ✓ | ✗ | ~ (unresolved) | ✓ |
| R2 agents stay git-blind | ✓ | ✗ | ✗ (`but agent`) | ✓ |
| R3 no TTY prompts | ✓ | ~ | ~ | ✓ |
| R4 no new auth/dependency | ✓ | ✗ | ✗ | ✓ |
| R5 solves a real stacking need | ✗ | ✓ | ✓ | ✓ |

**Pick: A now, D as the documented fallback — not built yet.**

R5 is the only requirement GitButler (B, C) or the bespoke extension (D) win that "do
nothing" doesn't, and R5 came back negative: no paper cut, no prior use of the `--base`
flag for this, nothing in `state/tasks/` shaped like a stack. Building D today would be
designing for a hypothetical. R1 and R2 are the requirements that rule out B and C
outright, and they're not negotiable — they're stated as deliberate in `CLAUDE.md` and
`docs/concepts.md`, not incidental side effects available to trade away for a nicer PR
stacking UX.

What this gives up: if a real chained-task case shows up, Captain doesn't get GitButler's
maintained restack/conflict UX or its TUI for free. It gets a ~20-line addition instead
(`CAP_PARENT` in `task.env`, one changed flag in `cap-land`'s `gh pr create` call, a new
`cap-restack` that's a thin wrapper over `git rebase`) written the day the need is real,
not before.

## Pushback

GitButler solves "I'm one person switching between branches by hand in one directory."
Captain never has that problem — every task already gets its own directory, which is a
stronger guarantee than GitButler's virtual-branch overlay, not a weaker one. Reaching for
a branch-management product to get stacked PRs, when the actual gap is "no PR-base
tracking across chained tasks," is solving the wrong layer. If the goal was specifically
stacked PRs on repos Captain doesn't control the pipeline for, that's a different
question — but for Captain's own worktrees, plain `git rebase` plus one more field in
`task.env` gets the same outcome with zero new trust surface.

## Revision — R5 confirmed real, mechanism validated against GitButler's own source

The captain confirmed a concrete need: a pipeline stage that opens stacked PRs for
related/dependent tasks, including the hard case — a commit added or reworded deep in a
stack, with everything above it needing to update deterministically. Rather than dismiss
GitButler on priors, cloned `gitbutlerapp/gitbutler` (`cap explore`) and dispatched four
scout tasks against the real source: `notes/gitbutler/graph-rebase-3.md`,
`oplog-undo-3.md`, `forge-sync-3.md`, `cli-embed-3.md`.

Findings that change the plan from "do nothing" to "build D, precisely":

- **Restack mechanism.** GitButler's own graph editor, for a single linear branch with one
  tip ref and no merge commits (Captain's exact shape), reduces to the same thing cascaded
  `git rebase --onto <new-parent-tip> <old-parent-tip> <child-branch>` (bottom-up) does.
  The editor's extra machinery (ref-in-range placement, merge-topology preservation,
  cross-branch conflict continuation) exists for cases Captain doesn't have. Confirmed,
  not assumed: `graph-rebase-3.md` Q3.
- **Undo.** GitButler's oplog snapshots far more than refs (worktree, index, conflict
  state, metadata) because it protects uncommitted work in a shared workspace. Captain's
  worktrees are already isolated per task, so the equivalent safety net is narrower and
  explicitly confirmed sufficient for that narrower promise: snapshot `git for-each-ref`
  for the affected branches to a timestamped file before a restack; undo with
  `git update-ref`. `oplog-undo-3.md` Q5.
- **Force-push safety.** Use `git push --force-with-lease --force-if-includes origin
  <branch>:<branch>`, not a bare `--force`. Exact flags GitButler itself uses.
  `forge-sync-3.md` Q1.
- **PR continuity.** Pushing a rewritten branch to the same name does not need to
  close/reopen the PR or touch its review threads — confirmed, not assumed.
  `forge-sync-3.md` Q2.
- **PR base retargeting.** When a stack's shape changes (a parent lands and drops out),
  GitButler explicitly PATCHes each affected PR's base, bottom-to-top, after all ref
  pushes complete. Maps directly to `gh pr edit <number> --base <branch>`, run in that
  order. `forge-sync-3.md` Q3-Q4.
- **Embedding `but` itself: no.** It's a standalone CLI (no daemon/Tauri needed for
  stacking), but first use requires `but setup` and a per-repo sqlite metadata store —
  real bootstrap overhead `gh` doesn't have, plus 39 of GitButler's own crates including
  TUI dependencies. `cli-embed-3.md` verdict: conditional yes, but not a stateless
  `gh`-shaped dependency. Confirms: implement natively, don't shell out to `but`.

**Revised pick: build D**, with the mechanism above — cascaded `git rebase --onto` for
restack, `git for-each-ref`/`git update-ref` for undo, `--force-with-lease
--force-if-includes` for push, `gh pr edit --base` bottom-to-top for retargeting.
