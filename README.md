# captain

Captain gives one operator a repeatable way to run coding agents across project
repositories. Agents work in isolated project worktrees. Captain keeps the work
moving, checks the result, and leaves the delivery decision with the operator.

## A normal session

### Orient

Start from the current project map and task state. Choose one project, write a
brief with a concrete outcome, and include the evidence that will prove it.
Related defects belong in one brief when they share a subsystem or invariant.

### Dispatch

Start the task from the Captain repository. The agent works in a project
worktree outside this repository and leaves its changes uncommitted. The brief
is the agent's scope. The agent reports work outside that scope instead of
quietly widening it.

### Supervise

Watch the task until it is working, waiting for input, blocked, or finished.
Read the agent's output before sending direction. A follow-up message keeps the
same session and worktree when the task can continue from its current context.

### Verify

Check the diff and run the project's own tests, lint, and type checks. Fixes
should be reproduced directly before another review round. Captain's checks are
deterministic; gate reviews provide separate judgment about the diff.

### Accept and deliver

Decide whether the result meets the brief. Clean up readability when needed,
then commit the accepted changes and land them through the project's delivery
mode. A task that is ready to land has passed its required checks and reviews.

The loop looks like this:

    orient -> brief -> dispatch -> supervise -> verify -> review -> accept -> deliver

## Working agreements

- Project repositories contain project source. Captain contains briefs, task
  records, reports, and delivery state.
- Each task gets its own project worktree. Agents own source changes there.
- Agents do not commit or publish. Captain writes history and delivers accepted
  work.
- Scripts decide repeatable facts. Agents and operators decide questions that
  need judgment.
- Every step ends with evidence that the next step can inspect.

## First setup

Install Git, mise, Herdr, and at least one supported agent harness. From this
repository, install the pinned tools and run the repository checks:

    mise install
    mise run doctor
    mise run check

Captain's local doctor also installs the cap link in ~/.local/bin. Register
the projects on the host before the first dispatch.

## Maintain Captain

The README describes the operator's session. The rest of the repository has
more focused responsibilities:

- [Development](docs/development.md) covers setup and changes to Captain.
- [Commands](docs/commands.md) is the flag and command lookup.
- [Concepts](docs/concepts.md) defines the runtime model.
- [Architecture](docs/architecture.md) maps state to modules.
- [Operations](docs/operations.md) records live contracts and recovery paths.
- [Skills](docs/skills.md) describes tracked external skills.
- [Rules](rules/code.md) and [comment rules](rules/comments.md) guide changes.
- [North](NORTH.md) defines the product boundary.

Use cap help when a command's current flags matter. The scripts and generated
state remain the source of truth for exact behavior.
