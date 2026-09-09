# Concepts

## Captain and project worktrees

Captain stores briefs, notes, config, and task state. Project repos store the actual source code.

Each task gets its own Git worktree under `CAP_WORK_ROOT`, outside the Captain repo. This prevents agents from changing Captain or inheriting its `CLAUDE.md`.

A `ship` task's worktree checks out a new branch, since its changes will be committed. A `scout` task never commits, so it gets a detached worktree with no branch instead - a clean, isolated view of the base, not the primary checkout's possibly-dirty working directory.

An agent is told only what its task needs: where to work and what to leave uncommitted, not branch names, worktree paths, or how Captain will deliver the result.

## Task lifecycle

1. `cap spawn` creates the branch, worktree, task record, and agent session.
2. `cap crew`, `cap peek`, and `cap watch` show what agents are doing.
3. `cap check` checks changed and untracked files for problems.
4. `cap cleanup` cleans up comments and readability.
5. `cap commit` stages and commits the changes.
6. `cap gate` runs two independent reviews before the work lands.
7. `cap land` opens a pull request or merges the branch.
8. `cap drop` removes the task after it is finished or explicitly discarded.

`cap commit` snapshots the worktree's full state before the commit agent
reshapes it into commits, under a `log/<slug>-<timestamp>` branch. If the
final commit sequence's tree matches the snapshot, the history is promoted
and the snapshot is deleted. If it does not, `cap commit` fails and keeps the
snapshot, since something changed the code, not just its shape.

A task can also be stacked on another task. `cap spawn --stack <parent-slug>` cuts it from the parent's branch instead of the base branch.

`cap restack <slug>` moves stacked tasks onto the parent's current tip after it changes. `cap land <slug> --merge` does the same after the parent lands.

Agents write code. Captain handles commits, delivery, and cleanup.

## Project modes

`pr` pushes the branch and opens a pull request.

`local` merges the branch into the base branch.

`scout` writes a report without delivering code changes.

## Models, profiles, tiers and roles

A profile is a harness, a model and a default effort, named in `config/captain.conf`.
`cap ask <profile>` runs a one-shot agent under one.

A tier is a capability class: `heavy`, `standard`, `cheap`. Its members are interchangeable
for the kind of thinking it names and live on different accounts on purpose. Tiers stop at
`opus` and `terra`; the profiles above them belong to no tier and are asked for by name.

A role is what a dispatch is for: `crew`, `scout`, `gate-a`, `gate-b`, `chore`. Each role
belongs to a tier and does not leave it.

Captain resolves a role at the moment of dispatch, from measurements only: the account's
rate-limit windows, and whether a harness has actually rejected a profile. A full window
moves work to a peer on another account. It never moves work to a smaller model, and when
no peer is admissible Captain refuses and says when capacity returns.

`cap budget` shows the readings, the tiers, and what each role resolves to.

The model and effort a profile names are facts about the account, so Captain asks rather
than trusting the table. The codex app-server answers `model/list` with every model the
account can reach and the efforts each one accepts, and `cap models` prints that against
`CAP_ASK_PROFILES`: a profile naming a model or an effort the account does not have is
refused by `cap ask` and `cap spawn` before a session starts. The claude harness publishes
no equivalent, so its aliases go unchecked and `cap models` reports only what the status
line has watched a session resolve them to.

Which tier a model belongs to is not in that answer and never will be. The catalog says
`gpt-5.6-terra` exists and accepts `xhigh`. It does not say terra is the right reviewer for
work that has to be right the first time. Facts are discovered; that judgment stays in
`config/captain.conf`.

## Project conventions

`cases/<project>/conventions.md` stores project-specific checks.

The project's own instruction files are still the source of truth. `cap conventions` creates the file. Update it when you find a check worth reusing.
