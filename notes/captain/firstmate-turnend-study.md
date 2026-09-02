# Firstmate turn-end study

## 1. Finding

The child-to-parent mechanism is firstmate’s explicit status protocol, not
`fm-turnend-guard.sh`. `bin/fm-brief.sh:184` embeds `$STATE/$ID.status` in every
brief. Its ship contract (`:419-425`) and scout contract (`:343-369`) tell the
child to append `done:`, `blocked:`, `needs-decision:`, or `failed:` lines, and
say that each append wakes firstmate. `bin/fm-watch.sh:1159-1167` classifies
new status bytes, not just the last line, and `:1636-1696` queues and wakes on a
captain-relevant event. `bin/fm-classify-lib.sh:67-78,129-150` owns the
vocabulary. This is the proactive child report; the supervisor need not read
terminal output.

`bin/fm-crew-state.sh:4-18` explicitly calls the status file an append-only
event log, then derives current state from an authoritative run step or pane
state when available. `bin/fm-fleet-snapshot.sh:4-7,33-40` is a read-only
aggregate, and `bin/fm-fleet-sync.sh:1-27` only refreshes project clones.
Neither is the child-report transport.

The turn-end guard is self-supervision. Its header says it guards a primary,
including the main home or a secondmate home, while child crew/scout worktrees
are exempt (`bin/fm-turnend-guard.sh:2-5`). It says the push hook runs when the
primary is about to end a turn (`:7-13`). The docs repeat that Claude and Codex
register these hooks for the primary (`docs/turnend-guard.md:50-55`) and list
child worktrees as outside scope (`:142-146`). `fm-claude-stop-autoarm.sh:2-14`
likewise owns watcher continuity for Claude primaries. It is not child
completion reporting. Firstmate’s busy layer is separate too:
`bin/fm-busy-lib.sh:2-12` says `.turn-ended` files are wake notifications, not
current-state truth.

## 2. Captain minimum viable pattern

After `cap-spawn` creates `$tree` and `state/tasks/$slug/task.env`, it should:

- Define absolute task paths such as `status.log` and `turn-ended` under
  `state/tasks/$slug`, and put the status path in the generated contract.
- Tell every child to append `done: ...`, `blocked: ...`, `needs-input: ...`, or
  `failed: ...` for supervisor-actionable outcomes, then stop. Use `working:`
  when resuming. Use the same protocol for ship and scout; for scout, `done`
  means the report is ready.
- Merge one task-specific `Stop` command into the worktree’s Claude
  `.claude/settings.json` or Codex `.codex/hooks.json`, preserving existing
  hooks. The command can be an absolute `touch .../state/tasks/$slug/turn-ended`
  and should always exit zero. Exclude generated config from Git cleanliness
  checks and remove it during `cap-drop`.

The Stop marker is only a turn-end notification. It must not be called `done`,
because Stop also fires on intermediate turns. The status log is authoritative
for completion and blockers.

`cap-watch` should inspect new status events and marker mtimes before any pane
capture. It can report `DONE`, `BLOCKED`, or `NEEDS_INPUT` immediately, and use a
marker-only event as `TURN_END`/attention. `cap-fleet` should give explicit
status precedence, then show live/turn-ended attention, then retain the idle
hash as a fallback. Keep the fallback for missing status or hooks, and never
auto-land or auto-drop on silence. This remains a manually run, cheap file poll;
it assumes no permanent watcher daemon.

## 3. Firstmate overkill

Do not copy the durable wake queue, keyed decision folds, generation-bound
acknowledgements, watcher auto-arm/single-flight machinery, semantic busy
adapter matrix, remote secondmate routing, or the large fleet snapshot. They
solve firstmate’s always-on, multi-home, multi-backend supervision problem.
Captain has one interactive operator, Herdr panes, and two harnesses. The
status protocol plus a Stop notification and idle backstop is enough for this
shaping pass. `fm-fleet-sync.sh` is unrelated.

## 4. Decisions before implementation

- Confirm that explicit status is the source of truth and Stop is only a wake.
- Decide whether `needs-input` is distinct from `blocked`, and whether status is
  append-only with a cursor or a single current-state file.
- Decide the fallback when a hook or status write fails. Recommended: retain
  idle detection, surface pane exit, and require human inspection.
- Confirm the protocol applies to both ship and scout.
- Decide how to merge or restore pre-existing project hook configuration without
  overwriting it.
