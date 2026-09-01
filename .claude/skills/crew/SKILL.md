---
name: crew
description: Dispatch project work to agents in isolated worktrees, supervise their sessions, and deliver accepted results. Use for parallel work, background work, and project code changes.
---

# Crew

`docs/commands.md` is the command reference. `docs/concepts.md` defines the lifecycle.
This skill defines the brief, supervision, and decision boundaries.

## Write the brief

An agent starts with only its worktree and brief. Include:

- **Outcome:** what must be true when the task is done.
- **Constraints:** interfaces, files, and behavior that must remain stable.
- **Evidence:** a command, test, or behavior that will prove the outcome.

State the result, not a sequence of keystrokes.

```sh
cap spawn fix-auth-retry backend -f - <<'EOF'
Outcome: a 429 from the token endpoint retries with backoff instead of surfacing to the caller.
Constraints: keep retry policy in transport.ts. Do not change the public client interface.
Evidence: a regression test fails before the change, passes after it, and the existing suite is green.
EOF
```

Choose `--scout` for investigation. Scout tasks write a report and leave project code
unchanged. Ship tasks produce a branch that can be reviewed and delivered.

## Supervise

Use `cap watch` to wait for an idle or exited session. When it returns, run `cap fleet`
and inspect the named task with `cap peek`. A quiet agent may be finished, blocked, or
stuck. Send a correction only after reading its output.

## Finish

Agents leave ship changes uncommitted. After the result is accepted:

```sh
cap check <slug>
cap cleanup <slug>
cap commit <slug>
cap land <slug>
```

`cap cleanup` is a comments and readability pass. `cap commit` stages and commits. Both
are separate consults, so neither pass shares the implementer's attention and context.

## Captain decisions

- `cap land` publishes or merges according to the project mode. Add `--merge` only when the
  captain has approved the pull request merge.
- `cap drop` protects unlanded work. Inspect a refusal before using `--force`.
- An agent reports problems outside its brief. Create a separate task instead of widening
  the current one silently.

## Report

Report what landed, what failed, and what needs a decision. Include the output that proves
failure. Do not turn retries or tool mechanics into status updates.
