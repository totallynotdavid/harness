---
name: reconcile
description: Start-of-day orientation - read what is actually open across every project and the live crew, then propose what to work on. Use when the captain asks where things stand, what is pending, or what to do next.
---

# Reconcile

Read the world; do not ask the captain to remember it.

```sh
cap reconcile           # local: dirty trees, unpushed commits, stashes, stray worktrees, crew
cap reconcile --remote  # adds your open PRs, review requests, assigned issues
```

Then report, in this order, and nothing else:

1. **Needs a decision**: things stalled on the captain. Each one: what is blocked, the
   options, and your recommendation. This is the only section that is allowed to be long.
2. **Under way**: live agents and what each is on. One line each.
3. **Open**: unlanded work, ranked by what it is costing to leave open. Not an inventory
   dump; leave out what does not matter today.
4. **Suggested next**: one to three, with why now.

Uncommitted changes sitting in a project for weeks are a finding, not a row in a table.
So is a branch that was never landed and a PR nobody reviewed. Say so.

If nothing needs the captain, say that in one line. Do not manufacture status.

## Setting up the day

To reopen several projects at once, spawn one agent per project with a status brief
and let them report in parallel: but only when there is real work in each. Do not spawn
a crew to read git.
