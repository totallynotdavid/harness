# Terms

Use concrete names. Define a term here only when it is part of a command, a
stored record, or a boundary that needs a precise distinction. Do not use a
metaphor when a direct noun names the same thing. Do not force one word to name
different things.

## People and processes

- **Captain**: the repository and CLI.
- **operator**: the person who decides what to do and what to deliver.
- **agent**: a spawned actor working in its own project worktree.
- **session**: one running conversation with an agent tool.

## A task

- **task**: a unit of work with a slug, a project worktree, and a `task.env` record.
- **scope**: the repository paths a task may change (`CAP_OWNS`).
- **kind**: `ship` or `scout` (`CAP_KIND`). It says whether the task produces
  source changes or a report.
- **mode**: `pr`, `local`, or `scout` (`CAP_MODE`). It says how completed work
  is delivered. A scout task always uses scout mode.
- **brief**: the file describing the task's outcome (`brief.md`).
- **contract**: the task instructions and status protocol handed to an agent
  (`contract.md`).
- **status**: a task's current condition: `done`, `blocked`, `needs-input`,
  `failed`, `working`, `idle`, or `exited`. It comes from live session data,
  gate records, and the task log. It is not the same as stored state.

## Batches and delivery

- **batch**: a named set of tasks with disjoint scopes (`cap batch`).
- **check**: the deterministic pass over a diff, with no model involved
  (`cap check`).
- **gate**: an independent model review of a diff, ending in `PASS` or `FAIL`
  (`cap gate`).
- **review**: the general act of evaluating a change. It includes checks and
  gates.
- **deliver**: push, open a pull request, merge, or write a scout report
  (`cap deliver`).
- **merge**: the Git operation used by local delivery or pull-request delivery.

## One-shot agents

- **profile**: a named harness, model, and effort configuration
  (`CAP_ASK_PROFILES`, `cap ask <profile>`).
- **role**: the kind of work being dispatched, such as `task`, `scout`, or
  `gate-a`.
- **tier**: a group of profiles that can perform a role.
