# Architecture

Captain is a shell CLI. Each part of its state has one source of truth.

| Concern | Source | Code |
| --- | --- | --- |
| Projects | `config/projects.tsv` | `bin/cap-map`, `bin/lib.sh` |
| Models and roles | `config/captain.conf` | `bin/lib.sh`, `bin/cap-spawn` |
| Tasks | `state/tasks/<slug>/` | `bin/cap-spawn`, `bin/lib.sh` |
| Worktrees | Git and `CAP_WORK_ROOT` | `bin/cap-spawn`, `bin/cap-drop` |
| Restack snapshots | `state/restacks/` | `bin/cap-restack`, `bin/lib.sh` |
| Package-manager caches | `CAP_CACHE_ROOT` | `bin/lib.sh` |
| Project conventions | `cases/<project>/conventions.md` | `bin/cap-conventions`, `bin/cap-check` |
| Notes and reports | `notes/<project>/` | task and scout commands |
| Project list | `map.md` | `bin/cap-map` |
| Skill sources | `config/skill-sources.tsv` | `bin/cap-skills`, `bin/cap-explore` |
| Installed skills | `.claude/skills/` | `bin/cap-skills` |

`bin/cap` sends each command to its `bin/cap-*` script. `bin/lib.sh` contains shared helpers for config, projects, tasks, panes, and Git.

Captain does not copy project source into this repo. Tasks use Git worktrees under `CAP_WORK_ROOT`.

`cap land` moves finished work into project history or a remote pull request.

## Branch naming

A ship task's branch is `cap/<slug>` - namespaced so Captain's own tooling can
find and filter its branches (`git branch --list 'cap/*'`) without colliding
with a human's branch of the same name. A `log/<slug>-<timestamp>` branch is
a throwaway snapshot ref, created by `cap commit` to verify a history
rewrite; it is deleted once verified, or kept for inspection if it is not.
