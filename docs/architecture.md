# Architecture

Captain is a shell CLI with one source of truth for each kind of state. The
entry point selects a command. The command loads shared modules. The modules
read or update one state store under an explicit lock when the state is shared.

## Data ownership

| Concern | Source | Main implementation |
| --- | --- | --- |
| Projects | config/projects.tsv | bin/cap-map, bin/lib/ |
| Local project paths (per host) | state/local-paths.tsv | bin/lib/, bin/cap-map, bin/cap-doctor |
| Models and profiles | config/captain.conf | bin/lib/, bin/cap-spawn |
| Tasks | state/tasks/<slug>/ | bin/cap-spawn, bin/lib/ |
| Worktrees | Git and CAP_WORK_ROOT | bin/cap-spawn, bin/cap-drop |
| Restack snapshots | state/restacks/ | bin/cap-restack, bin/lib/ |
| Batches | state/batches/<name>.tsv | bin/cap-batch |
| Tool provisioning | config/tools/<project> and lockfiles | bin/lib/, bin/cap-spawn |
| Verified project commits | state/verified/<project>/ | bin/cap-verify |
| Path ownership | CAP_OWNS in task.env | bin/cap-spawn, bin/hooks/guard-task-paths.sh |
| Memory measurements | state/peaks/<project> | bin/cap-verify, bin/lib/ |
| Project conventions | cases/<project>/conventions.md | bin/cap-conventions, bin/cap-check |
| Commit plans | state/tasks/<slug>/commit-plan.json | bin/cap-commit, bin/cap-deliver |
| Behavior tests | tests/ | tests/run, mise run test |
| Static checks | tests/static/lint-* | mise run lint, mise run check |
| Reports and notes | notes/<project>/ | task and scout commands |
| Project map | map.md | bin/cap-map |
| Skill sources | config/skill-sources.tsv | bin/cap-skills, bin/cap-explore |
| Installed skills | .claude/skills/ | bin/cap-skills |

map.md and state/ are machine state. Their files are not product
documentation unless a command explicitly records a report there.

## Command layers

- bin/cap resolves a command from this checkout's bin/ directory.
- bin/cap-* scripts parse command arguments and own command-specific side effects.
- bin/lib.sh loads shared modules in numeric order.
- bin/lib/ modules own one cross-command concern: configuration, resources,
  ownership, processes, locks, tasks, queues, state, Git, stacks, or dispatch.
- bin/hooks/ protects the boundaries between a captain, an agent, and the
  repositories they can write.

The numbered modules are a load order, not a call graph. A module may use
functions defined earlier in the load order. Keep a new shared function in the
module that owns its state or external boundary.

## State flow

    brief
      -> task.env and task worktree
      -> agent output and status.log
      -> check, verify, cleanup, and gate records
      -> commit-plan.json and Git commits
      -> pull request, merge, or scout report

Commands that update task state take the task lock. cap send queues a message
when a task is busy and delivers it after the holder releases the lock. Gate
records include the fingerprint they reviewed, so a passing review is valid
only for the tree it actually saw.

## Branches

A ship task uses cap/<slug>. The namespace lets Captain find its branches
without colliding with a human branch of the same name. cap commit creates a
temporary log/<slug>-<timestamp> snapshot while it rewrites the task history.
The snapshot is deleted after the final tree matches the pre-commit tree and
kept when the rewrite needs inspection.
