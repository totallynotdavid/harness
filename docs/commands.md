# Commands

Run `cap help` for all flags.

## Agents

| Command | What it does |
| --- | --- |
| `cap spawn <slug> <project>` | Start an agent for a project. |
| `cap crew` | Show all agents and their status. |
| `cap peek <slug> [lines]` | Show recent agent output. |
| `cap send <slug> "<text>"` | Send a message to an agent. |
| `cap watch` | Wait until an agent needs input. |

## Review and delivery

| Command | What it does |
| --- | --- |
| `cap check <slug>` | Check an agent's changes. |
| `cap check --repo <project> [--base REF]` | Check project changes without an agent. |
| `cap cleanup <slug> [profile]` | Clean up comments and readability. |
| `cap gate <slug>` | Run two independent reviews (roles `gate-a`, `gate-b`) before landing. |
| `cap commit <slug> [profile]` | Stage and commit changes. |
| `cap land <slug> [--merge]` | Push, open a PR, or merge the work. |
| `cap restack <slug> [--undo]` | Move stacked tasks onto `<slug>`'s tip. |
| `cap drop <slug> [--force]` | Remove a task and its worktree. |

`cap land` requires committed changes. Use `--merge` to merge a pull request.

## Projects

| Command | What it does |
| --- | --- |
| `cap map [--sync]` | Update the project list. |
| `cap reconcile [--remote]` | Show open work across projects. |
| `cap project <name> [mode] [model]` | Show or change project settings. |
| `cap budget` | Show measured quota, and what each dispatch role resolves to now. |
| `cap papercut "<text>"` | Log a problem with Captain. |
| `cap explore <owner/repo> [--fresh]` | Clone a repo for inspection. |
| `cap history --repo <name>\|--task <slug> [opts]` | Search past agent sessions. |
| `cap conventions <project>` | Create project conventions. |

## Skills and consults

| Command | What it does |
| --- | --- |
| `cap ask <profile> "<prompt>" [--dir D]` | Run a one-shot agent. |
| `cap ask --list` | List profiles. |
| `cap skills list [nick]` | List available skills. |
| `cap skills add <nick>/<name>` | Add a skill. |
| `cap skills diff <name>` | Compare a skill with its source. |
| `cap skills sync` | Update skill sources. |
| `cap skills rm <name>` | Remove a skill. |
