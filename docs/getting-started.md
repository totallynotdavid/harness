# Getting started

Captain runs coding agents across multiple projects.
Install Git, `mise`, Herdr, and Claude Code or Codex.

```sh
mise install
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
