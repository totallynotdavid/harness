# Terms

One word per concept, everywhere in this repo: every script, doc, comment, and skill
Captain owns. When a comment or doc needs a synonym for one of these, that is a sign the
concept split in two - fix the word, not the sentence.

Does not apply to `notes/` (point-in-time research, kept as the source described it) or to
imported skills (`config/skill-snapshots.list`; see `docs/skills.md`).

## Roles

- **captain**: whoever is driving the CLI right now. Usually an AI session; could be the
  operator's own hands. Decides whether work lands or is discarded.
- **operator**: the human. Sets direction and makes the calls that need human judgment.
  Not the captain - the captain is a seat, the operator is a person.
- **agent**: one spawned actor, running a task in its own worktree.
- **crew**: agents as a group - the brief you write them, how you supervise them, and the
  live status view (the command `cap crew` and its table). One word for both; context
  carries the difference the way "my team" and "check the team" don't need separate nouns.

## A task

- **task**: a unit of work with a slug, a worktree, and a `task.env` record.
- **kind**: `ship` or `scout` (`CAP_KIND`). Does this task's agent produce a branch, or a
  report? Set once, at `cap spawn`.
- **mode**: `pr`, `local`, or `scout` (`CAP_MODE`, `config/projects.tsv`). How a project's
  finished work gets delivered. A project's default; a scout-kind task forces its own mode
  to `scout` regardless of the project's default.
- **brief**: the file the operator writes describing a task's outcome (`brief.md`).
- **contract**: what `cap spawn` hands the agent - the fixed task rules plus the brief
  (`contract.md`).

## Watching a task

- **pane**: the terminal surface an agent runs in. Herdr's own word (`herdr pane ...`,
  `CAP_PANE`). Not "window".
- **status**: a task's current condition - `done`, `blocked`, `needs-input`, `failed`,
  `working`, `idle`, or `exited` (`status.log`, `task_status_*`, `cap crew`'s STATUS
  column). Not "state".
- **watch**: block until a task needs input or exits (`cap watch`).

## Landing

- **check**: the deterministic pass over a diff, no model involved (`cap check`).
- **gate**: two independent model reviews of a diff before it lands, each ending
  `PASS` or `FAIL` (`cap gate`).
- **review**: the general word for evaluating a diff - covers `check`, `gate`, and the
  `review` skill together. Not a command name by itself.
- **land**: push, open a PR, merge, or file a scout report - the terminal step
  (`cap land`).
- **merge**: the git mechanism `land` uses, local or through a PR. One step inside
  landing, not a synonym for it.

## Running an agent once

- **profile**: a name, harness, and model triplet for a one-shot agent
  (`CAP_ASK_PROFILES`, `cap ask <profile>`). Not "role".
