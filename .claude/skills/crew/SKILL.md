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

## Dispatch in parallel

`cap check` reports a `collisions` section naming any other live task in the project
changing the same files, and `cap land` trial-merges before touching the base and refuses
a branch that would conflict. Both are deterministic. What they cannot do is prevent the
collision, only catch it, so plan against these:

- **Assign every path, not just the interesting ones.** Name the files no task may touch
  and say what to do instead: report the needed change rather than making it. The root of
  a repository belongs to nobody by default, which is where parallel tasks collide.
- **Install every dependency in the base commit.** `pnpm add` and its equivalents rewrite
  the manifest and the lockfile, which are global. If a task needs a new one, it reports
  and waits.
- **Name shared primitives and give them one owner.** A rule two layers need is a planning
  decision. Deferring it into the briefs produces two implementations of it.
- **Plan the integration step.** N parallel tasks need an N+1th that merges them, with a
  definition of done that builds, typechecks, runs the whole suite, and boots the app.

When the base is thin, prefer one task that builds a single slice end to end, then fan out
against the pattern it establishes. Agents dispatched against a one-commit repository have
nothing to copy and no settled root to share.

Choose `--scout` for investigation. Scout tasks write a report and leave project code
unchanged. Ship tasks produce a branch that can be reviewed and delivered.

## Supervise

Use `cap watch` to wait for an idle or exited session. When it returns, run `cap crew`
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
