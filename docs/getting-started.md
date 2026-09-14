# Getting started

Captain runs coding agents across multiple projects.
Install Git, `mise`, Herdr, and Claude Code or Codex.

```sh
mise install
mise run doctor
```

The repository doctor runs mise's host diagnostics, confirms this checkout's `mise.toml`
is active, checks that its tools are installed, and validates the task graph. Running
`cap doctor` also installs a `~/.local/bin/cap` link to this checkout so later shells can
find Captain.

Run the behavior tests while developing, or run the full repository gate before landing:

```sh
mise run test
mise run check
```

Point Claude Code's status line at Captain, in `~/.claude/settings.json`. Captain reads the
account's rate-limit windows from what the harness already hands that line, and uses them
to size every agent it dispatches:

```json
"statusLine": { "type": "command", "command": "<captain>/bin/cap-statusline" }
```

Captain scans `$HOME/git` for projects by default. Register them with:

```sh
cap map --sync
cap project
```

Start a task with a registered project and a brief:

```sh
cap spawn fix-login crm --brief /path/to/brief.md
```

Check the agent or wait for it to finish:

```sh
cap crew
cap watch
cap peek fix-login
```

Then check and land the work:

```sh
cap check fix-login
cap cleanup fix-login
cap commit fix-login
cap gate fix-login
cap land fix-login
```

Agents write the code. Captain handles the task and delivery.
