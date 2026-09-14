# Commands

Run `cap help` for all flags.

## Agents

| Command | What it does |
| --- | --- |
| `cap spawn <slug> <project>` | Start an agent for a project. |
| `cap wave check <name>` | Verify a wave is a real partition of the tree. |
| `cap wave spawn <name>` | Start a wave's tasks, as many as memory allows. |
| `cap crew` | Show all agents and their status. |
| `cap sessions` | Show every agent session on this machine. |
| `cap peek <slug> [lines]` | Show recent agent output. |
| `cap send <slug\|session> "<text>"` | Send a message to a task agent or live ask session. Labels include `gate-A-<slug>`, `commit-<slug>`, and `cleanup-<slug>`. |
| `cap watch` | Wait until an agent needs input. |

## Review and delivery

| Command | What it does |
| --- | --- |
| `cap check <slug>` | Check an agent's changes. |
| `cap check --repo <project> [--base REF]` | Check project changes without an agent. |
| `cap cleanup <slug> [profile]` | Clean up comments and readability. |
| `cap gate <slug> [--full]` | Review the changes: gate B, or a full A+B review with `--full`. An exact current PASS is reused. Suspected findings stay visible without failing the gate. |
| `cap step <slug> [STEP]` | Advance a task: check, verify, cleanup, gate, commit. Stops at a gate FAIL and before landing. A named step is refused until the steps before it are done. |
| `cap commit <slug> [profile]` | Stage and commit changes. |
| `cap land <slug> [--merge] [--squash\|--rebase\|--merge-commit]` | Push, open a PR, or merge the work. |
| `cap restack <slug> [--undo]` | Move stacked tasks onto `<slug>`'s tip. |
| `cap drop <slug> [--force]` | Remove a task and its worktree. |

`cap land` requires committed changes. Use `--merge` to merge a pull request.
Pull requests use GitHub's rebase strategy by default. Use `--squash` or
`--merge-commit` when a different history shape is intended.

## Projects

| Command | What it does |
| --- | --- |
| `cap map [--sync]` | Update the project list. |
| `cap reconcile [--remote]` | Show open work across projects. |
| `cap doctor [--diff REPORT]` / `cap doctor --remote HOST [--path CAP_HOME]` | Describe this host or compare it with a host discovered over SSH. |
| `cap project <name> [mode] [model]` | Show or change project settings. |
| `cap budget` | Show measured quota, and what each dispatch role resolves to now. |
| `cap models [--refresh]` | Show what each harness offers, and check the profile table against it. |
| `cap papercut add <subject> "<text>"` | Log a problem with Captain. The subject is a part of Captain (`cap papercut subjects`); a project is refused. |
| `cap papercut close <id>` | Remove a fixed paper cut. |
| `cap grant <slug> <path> [--take]` | Add a repository-relative path or glob to a task's ownership boundary. |
| `cap explore <owner/repo> [--fresh]` | Clone a repo for inspection. |
| `cap history --repo <name>\|--task <slug> [opts]` | Search past agent sessions. |
| `cap conventions <project>` | Create project conventions. |

## Skills and consults

| Command | What it does |
| --- | --- |
| `cap ask <profile> "<prompt>" [--dir D] [--label L]` | Run a one-shot agent. |
| `cap ask --list` | List profiles. |
| `cap skills list [nick]` | List available skills. |
| `cap skills add <nick>/<name>` | Add a skill. |
| `cap skills diff <name>` | Compare a skill with its source. |
| `cap skills sync` | Update skill sources. |
| `cap skills rm <name>` | Remove a skill. |
