# The rest of the plan, delivered as one task

Read `notes/captain/plan.md` in full first - it is the sequencing argument for
everything below and states what NOT to touch (do not rewrite anything above
the transport line, do not replace herdr, do not touch role/tier dispatch, do
not reformat `bin/` with shfmt). Then read
`notes/captain/briefs/interactive-dispatch.md` and
`notes/captain/briefs/dispatch-cost-and-scope.md` in full - both are written
already and this brief does not repeat their content, only where each piece
fits in one delivery.

This is stages 3 through 7 of the plan, the two briefs above, and the
cross-cutting items plan.md lists, done as one task instead of five gated
rounds. Implement everything below before reporting back. Self-verify each
piece live as you finish it - the way `cap-headless` and `pipeline-hardening`
did - rather than saving verification for the end, but do not stop to ask for
a round of review partway through. One report, when the whole thing works.

## Why one task, not five

Real dependencies run through this in one direction, and doing it as five
separately gated tasks paid for the same review five times over on
`pipeline-hardening` - eight gate rounds for one stage's worth of work. Doing
it as one task means the parts that depend on each other are never reviewed
before the piece they need exists.

## Order to build in

The order below is load-bearing. Do not start stage 3 before
`interactive-dispatch.md` lands inside this same task, because stage 3's
structured findings have to be read back from whatever channel
`interactive-dispatch.md` leaves in place, not from the `stream-json` block it
deletes.

### 1. `interactive-dispatch.md` in full

One dispatch path for `cap spawn` and `cap ask` alike, per that brief's
"The shape" section. This removes `-p`, `--output-format stream-json`,
`--verbose`, `codex exec --json`, and `pane_dispatch` as a mechanism separate
from `pane_launch`. Build the two harnesses' turn-end signal the brief flags
as the genuinely divergent part first, not last: claude gets it from a `Stop`
hook, codex has none, so decide codex's answer-channel and turn-end signal
before wiring the claude side, so one shape covers both rather than bolting a
special case onto a claude-shaped design afterward.

Fold in the cross-cutting item from `plan.md` this brief already names as
belonging here: `cap ask` must install the ownership guard when `--dir` points
at a task worktree, which it does not today.

### 2. Gate findings become structured, not prose

Stage 3 of `plan.md`. `cap gate` asks for findings with a file, a line, a claim
and a severity, and computes `GATE: PASS`/`GATE: FAIL` from them instead of
parsing it out of an answer. Decide how a finding is carried back through the
dispatch path stage 1 just built - a JSON block in the final message, a file
the `Stop` hook payload points at, whatever stage 1's shape actually supports -
and say why in a comment at the decision point, not in a separate document.

This is also where `plan.md`'s "a verdict is not a result" defect gets closed:
a review that produced no real findings and no real reasoning must not be
accepted as a verdict just because the channel reported success. Decide what
makes a report substantive enough to trust and enforce it structurally, the
way `gate.json`'s fingerprint already refuses a stale review - not with a
comment asking a future reader to notice.

Update `cases/<project>/conventions.md`'s gate-miss ledger to be written by
`cap land` from structured findings, per `plan.md` stage 3's closing
paragraph, rather than left as a skill asking an agent to remember.

### 3. `dispatch-cost-and-scope.md`, sections 1, 2 and 4

Sections 3 and 5 of that brief already shipped as `pipeline-hardening`
(incremental gate review, the three lint checks). Build the rest now that
stage 1 above has replaced what they were blocked on:

- Section 1: record window-delta and exact token cost per dispatch, written
  against the same record `dispatch_log` already keeps.
- Section 2: gate A and gate B run concurrently, not in a `for` loop.
- Section 4: an `--effort` chosen per role in `config/captain.conf`, not left
  at the harness default for every claude profile.

### 4. `cap step`

Stage 5 of `plan.md`. Depends on stage 2 (task ownership, already landed) and
on this task's own section 2 above (structured findings, so `gate.json` is
worth trusting). `cap step <slug>` advances a task as far as it can from the
state already on disk and stops at a gate `FAIL` with findings or at landing,
per `NORTH.md`'s two human-reserved points. An out-of-order step is refused,
not silently reordered.

### 5. One ledger with a schema

Stage 7 of `plan.md`. `cap papercut` takes a subject and refuses an entry that
names a project, the way `cap spawn` already refuses a duplicate pane.
`paper-cuts.md` becomes generated output, the way `map.md` already is, not the
hand-edited store.

### 6. The harness-facing half leaves bash

Stage 6 of `plan.md`, done last and on purpose: rewriting `cap-ask`,
`cap-gate`, `cap-spawn` and whatever else now handles JSONL streams, schema
validation and structured findings is worth doing once, after sections 1
through 5 above have settled what those files actually do. `bin/cap-history`
is already Python; follow its shape. Bash keeps the git and worktree plumbing
- nothing there moves. Fold in the cross-cutting `cap-ask` restructuring item
from `plan.md` here: the inlined resume-key resolution, turn loop, result
parsing, session-limit classification, usage recording and error reporting
become separate, and harness dispatch becomes one `case`, not three top-level
`if ... exit 0` blocks - this was deliberately deferred at `cap-headless`
round 10 for exactly this moment.

## Also fold in, wherever they naturally land above

- Spawn preflight: refuse to start a task whose worktree cannot build, rather
  than let an agent discover that one failed turn at a time. Fits inside
  section 1 (`cap spawn`'s dispatch path) or section 4 (`cap step`'s
  advancement checks) - pick one and say why.
- Widen `task_lock` coverage beyond `cap gate`, `cap check`, `cap drop`,
  `cap land` and `cap cleanup` to whatever else in this task's own new surface
  mutates a task's state.
- `cap doctor`, comparing two Captain hosts, if it fits after everything above
  without forcing a design compromise elsewhere. Cut it rather than let it
  distort the rest.

## What not to touch

Everything `plan.md`'s own "Not in this plan" section names. Role and tier
dispatch. herdr as the pane layer `cap attach` still uses. Formatting passes
over files this task does not otherwise change.

## Constraints

Read `rules/code.md`, `rules/comments.md` and `rules/commits.md`. Keep commit
summaries to 50 characters or fewer and check them yourself before reporting.
Do not add a `Co-Authored-By` trailer, a session link, or any other AI credit
- a `commit-msg` hook now strips one if you do, so this is enforced, not only
asked for.

## Verifying

`mise run lint` and every `check:*` task must pass. For each section above,
show the live repro the section's own brief describes where one exists
(`interactive-dispatch.md`'s brittle-edges list, `dispatch-cost-and-scope.md`'s
measured timings). Where no prior brief specifies a repro, construct one: a
real gate round with a genuine defect for section 2, a real out-of-order
`cap step` call refused for section 4, a real project-named `cap papercut`
call refused for section 5.

This is a large task. Report progress in `status.log` as each numbered section
above completes, not only at the very end, so the captain can see where the
work is without asking. Do not commit; leave the result for `cap commit`.
