# Development

This document is for changing Captain. The README describes a normal operator
session. The command reference is a lookup, not the session contract.

## Set up

Install Git, mise, Herdr, and Claude Code or Codex. From the repository:

    mise install
    mise run doctor

mise run doctor checks the host tools and Captain's repository setup. cap doctor
also keeps the cap link in ~/.local/bin linked to this checkout so a new shell
uses the same Captain code.

Point Claude Code's status line at Captain if Claude dispatches will use quota
measurements:

    "statusLine": { "type": "command", "command": "<captain>/bin/cap-statusline" }

Register local projects with cap map --sync. The registry is machine-local; do
not commit it as project documentation.

## Change a behavior

Read the relevant module before editing it. Put a brief in the task record when
the change needs an agent. Keep source changes in a project worktree and leave
them uncommitted for Captain to inspect.

For a direct Captain change, use the same evidence standard as an agent task:

1. Reproduce the current behavior or state the existing contract.
2. Change the smallest responsible module.
3. Add a regression test when the behavior can be exercised deterministically.
4. Run the focused test and the full repository check.
5. Inspect the diff, including comments and documentation.

The full check is:

    mise run check

Use mise run test for the behavior suite and mise run lint for ShellCheck. Use
a focused test while iterating, then run mise run check before delivery.

## File responsibilities

- README.md explains the operator's session and expectations.
- docs/ explains Captain's design, runtime contracts, and contributor workflow.
- rules/ contains instructions agents load for code, comments, evidence, terms,
  and commits.
- NORTH.md defines what Captain is and is not.
- bin/ contains command entry points, hooks, and shared modules.
- tests/ contains behavior tests and static checks.
- config/ contains tracked defaults and tool provisioning instructions.
- cases/ and notes/ contain project-specific records and reports.

Keep a fact in one authoritative place. A command's flags belong in its help
output and docs/commands.md; a system invariant belongs in docs/architecture.md
or docs/operations.md; a local code invariant belongs beside the code that
enforces it.

## Before delivery

Review the changed files as a reader. Remove comments that describe visible
code. Move workflow or subsystem explanations into the document responsible
for them. Keep comments for local invariants, external behavior, and decisions
that cannot be expressed by clearer names or structure.

Captain's commit pipeline writes planned commit groups and checks their final
messages. Read rules/commits.md before changing history.
