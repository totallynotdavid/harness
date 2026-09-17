# How Captain works

Captain separates the operator's repository from the project repositories it
works on.

## Repositories and worktrees

This repository stores briefs, notes, configuration, and task state. Project
repositories store project source. A task gets a project worktree under
CAP_WORK_ROOT, outside this repository, so project agents cannot change Captain
or inherit its CLAUDE.md.

config/projects.tsv keys each project by its origin remote, not its local
path, so the registry is the same file on every host. Local clone location is
a per-host cache under state/, rebuilt by scanning CAP_ROOTS; a project
registered but not yet cloned on this host resolves to nothing until it is.

A ship task uses a branch because it will produce a deliverable. A scout task
uses a detached worktree because it produces a report and no branch.

## Task lifecycle

The task record is the durable handoff between commands:

    brief -> spawned -> working -> checked -> reviewed -> committed -> delivered

The agent owns working. Captain owns checks, reviews, commit creation, and
delivery. A task can stop at blocked, needs-input, or failed; those are reasons
to inspect the record, not successful completion.

The current status combines live pane state, gate records, and the task log.
The log explains why a task stopped. It does not prove that the task is still
running or ready to deliver.

Stacked tasks add one dependency: a child records its parent's branch tip.
Restacking moves the child onto a new parent tip and updates descendants in the
same pass. The child worktree must be clean before that rewrite.

## Delivery modes

- pr pushes a branch and opens a pull request.
- local merges the branch into the configured base.
- scout writes a report without delivering source changes.
- ignore refuses dispatch; the registry keeps a decision not to run work here.

The project registry supplies the mode. A scout task always uses scout mode.

## Dispatch roles

A profile names a harness, model, and default effort. A role names the kind of
work being dispatched. A tier groups profiles that can perform that role.

Quota selects an available profile inside the role's tier. It does not lower
the requested capability. If no profile in the tier is available, Captain
waits by refusing the dispatch and reports the capacity it observed.

cap budget exposes the measurements and the resulting choices. The catalog of
models is a harness fact. Tier membership and role capability remain Captain's
configuration.

## Project conventions

cases/<project>/conventions.md stores checks worth reusing for one project.
The project repository's own instruction files remain authoritative. Captain
records a convention when it helps a future task reach the project's checks
without rediscovering them.
