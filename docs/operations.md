# Operations

This document records live runtime contracts that matter while a task is being
checked, reviewed, or delivered. It describes the current system. The commit
history holds the incidents that led to these rules.

## Check the project directly

cap verify runs the project's own test, lint, typecheck, and build commands
inside its worktree. It reads those commands from the project configuration.
Each command writes a complete log before Captain copies the result to the
caller. A detached child cannot keep the caller's output pipe open.

Run direct checks before spending another review round on a question the
project's tools can answer. Passing checks do not replace model review: they do
not establish that the change is correct for cases the project does not test.

mise run doctor checks Captain's repository setup. cap doctor also repairs the
local cap path. The built-in mise doctor remains a host diagnostic.

## Review a task

cap gate <slug> runs the cheap gate by default. cap gate <slug> --full runs both
independent gates. Use the full form for the first review and before landing;
use the default form after an agent fixes a finding.

Each gate record stores the profile verdict and the fingerprint of the reviewed
tree. A task is ready only when both gates passed the current fingerprint. A
stale pass, a missing verdict, or a failed verdict leaves the task unready.

Before a gate, Captain synchronizes a task with the current base when Git can
do so cleanly. It reviews the branch from its merge base so a sibling's newly
landed commit is not treated as work made by this task. A merge conflict leaves
the diff available for inspection. A stash reapply conflict refuses the gate
and leaves the worktree for the task's agent to resolve.

## Task state

The live pane answers whether an agent is running. gate.json answers whether the
current tree is ready to land. status.log explains a blocked, failed, or
input-needed task. No log word can override the live pane or a stale gate
fingerprint.

cap send continues a live agent session. It checks context and compacts the
session before taking the task lock. If another command owns the task, the
message goes to a durable queue and the command returns. Queue delivery happens
when a locking command releases the task. Delivery is one confirmed attempt;
an unconfirmed attempt is recorded and removed rather than typed twice.

## Sessions and harnesses

Captain dispatches every agent call through a Herdr pane. cap spawn creates a
long-lived session. cap ask, gates, cleanup, and commit planning use print-mode
calls inside a pane and capture their output in a file. The pane makes the call
visible; it does not make a print-mode call interactive.

Claude session-limit failures are identified from the harness event, not from
the rendered answer. Captain records a resumable ask session when the harness
supports it. A matching call resumes a session only when its recorded context
is below the configured threshold; otherwise it starts fresh.

## Dispatch sizing

Captain chooses a profile from the requested role's tier. It uses recent rate
limit readings and recorded session-limit rejections. An unreadable meter means
unmeasured, so it does not hold work back. A full account moves work to another
profile in the same tier. It never silently replaces a role with a cheaper
tier.

Claude readings come from the configured status line. Codex readings come from
the app server or the newest rollout. Readings are scoped to their harness;
one account's window says nothing about the other.

## Recovery

- A task with a failed or stale gate needs a new check and review round.
- A task with a stash reapply conflict needs its own agent to resolve the
  worktree before review continues.
- A queued message is pending until a later locking command exits cleanly.
- A closed long-lived pane cannot be resumed through Captain today. Use the
  harness's own resume command or start a new task session.
