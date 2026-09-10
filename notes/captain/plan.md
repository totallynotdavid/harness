# Captain: what to build next, and in what order

Written 2026-09-10, after the first stage shipped. This is the sequencing
argument, not a task list. Each stage names what it unlocks for the next one,
because the ordering is the only part of this that is expensive to get wrong.

## The through-line

Captain's ideas are sound. Its substrate is wrong.

Nineteen paper cuts have Captain itself as their subject. Six of them are one
decision failing: an agent runs as a terminal pane and Captain reads its answer
off the screen. Four more are bash surprising us under `set -euo pipefail`.
That is ten of nineteen, and none of the six failed loudly. Each produced a
confident wrong answer: a gate review missing findings 1 to 5 that looked
complete, a real PASS recorded as UNKNOWN, a finished task reported as running,
a resumed session restating a verdict about code it had never read.

Screen-scraping does not crash. It lies. That is why it is worth a rewrite and
a lint is not enough.

Above that line the design holds up and should not be touched. Role and tier
dispatch sized from measured windows, with the refusal to ever substitute a
smaller model for a full one. `cap wave` seeing a collision that no per-task
command structurally can. The ownership guard as a hook rather than a paragraph
in a brief. Gate fingerprinting. The map.md and projects.tsv boundary. None of
those are the problem and none of them are in this plan.

## Stage 1: cap ask goes headless (done)

Shipped today as the `cap-headless` task. `cap ask` runs the harness with
`-p --output-format stream-json` and reads a structured result instead of a
pane.

What it removed: the viewport truncation workaround, the `^❯` prompt anchor,
the `ctx N% used` and `resets ... (UTC)` prose greps, `gate_verdict`'s fixed
tail window, and `limit_reset_epoch`. What it added: real session ids, exact
token usage against the model's own context window, cost per dispatch, and
quota read from a `rate_limit_event` that arrives on every call.

Evidence it worked: a 210-line answer came back whole, which is the exact
failure that lost findings 1 to 5 of two real gate reviews. `cap budget`
refreshed with no interactive session ever rendering a status line. A live
Gate B ran against local-env's real diff and recorded a genuine PASS.

It also turned up a bug nobody was looking for: neither harness invocation had
ever set its working directory to `--dir`'s target. The old pane transport hid
it, because herdr opened the pane in the right place.

## Stage 2: the gate emits findings, not prose

Moved ahead of the spawn rewrite on 2026-09-10. It depends only on stage 1,
it is much the smaller change, and a day of gate rounds on cap-headless
showed what prose costs. One `find` line was added in round five, deleted in
round six, restored in round seven and challenged again in round eight,
because a prose report carries no memory of what the last three rounds
established. In the same stretch a finding the captain owns and had deferred
was re-reported at full reviewer cost every round, with no way to mark it
taken. Both are addressability problems, not review-quality problems.

`cap gate` currently asks for a review and parses `GATE: PASS` out of the
answer. It should ask for structured findings, each with a file, a line, a
claim and a severity, and compute the verdict from them. codex has `--output-schema` for exactly this.

What it unlocks is not tidiness. A finding becomes addressable on its own, so a
fix round can be sent one finding at a time instead of resending a whole
review. Findings become comparable across rounds, so a defect the agent claims
to have fixed and has not is detectable rather than a thing the captain has to
notice. And `cases/<project>/conventions.md`'s gate-miss ledger can be written
by `cap land` instead of by a skill asking an agent to remember.

local-env is the argument. Its dev stack landed on classroom master by hand,
and the Gate A run that followed found six real defects in code that was
already shipped. Those findings had to be copied into
`notes/classroom/defects.md` by hand to survive at all, because a gate report
describes a branch and that branch had nothing left to land.

## Stage 3: cap spawn goes headless

The larger half. `cap spawn`'s agents are long-running, and `cap crew`,
`cap watch`, `cap send` and `cap peek` all currently guess at them from pixels.

Why it is next: every remaining transport paper cut lives here, and three
separate open problems collapse into it. `task_idle_age` checksums the last
forty lines of pane output to decide whether an agent is working; the event
stream says so directly. `pane_context_pct` greps a status line; `usage` is a
field. `cap send` types into a TUI in chunks because the input box drops
characters, then presses Enter up to three times and greps the pane to see
whether the message left the box; a resumed session takes the text as an
argument. NORTH.md's own open question, whether `cap resume` should exist, is
answered by Captain choosing the session id before launch.

It also closes the newest cut: `cap send` puts the captain's entire message in
argv, which is world-readable on this box and matched the agent's own process
when something tried to poll for its work.

What it costs, and this is the real price: the pane stops being the transport,
so the captain can no longer glance at a wall of live agents and type at one.
That affordance is worth keeping, so `cap attach <slug>` should resume the
session interactively in a pane on demand. Both harnesses support it. The
difference is that watching becomes a thing the captain asks for, not the
channel the pipeline depends on.

## Stage 4: cap step

Depends on 2 and 3 for state worth trusting.

The pipeline is eight commands the captain types in order, and the state needed
to know which one comes next is already on disk: `status.log`, `gate.json`, the
fingerprint, the `cleaned` marker. Deriving it by hand is why three tasks are
sitting done and unlanded right now and why the prompt hook has to nag every
turn.

`cap step <slug>` advances a task as far as it can and stops at the two points
NORTH.md reserves for a human: a gate FAIL with findings, and land. Out-of-order
steps get refused rather than documented.

## Stage 5: the harness-facing half leaves bash

A consequence of stages 1 and 2, not a taste. Bash is fine for git and worktree
plumbing and should keep it. It is the wrong tool for JSONL streams, schema
validation, concurrent state and retries, which is what the pipeline becomes.
The evidence is that we now maintain `bin/lint-andlist` because shellcheck has
no diagnostic for a footgun that bit us twice, and three of the four bash cuts
were silent wrong answers rather than crashes.

`bin/cap-history` is already Python. The harness-facing commands follow it.
Nothing else moves.

## Stage 6: one ledger with a schema

`paper-cuts.md` is a database in a markdown list. Its own header said it was not
for project bugs while seven of thirteen open entries were relq and rqueue
defects. That was fixed by hand today and the header now states the boundary,
which means the boundary is a sentence an agent has to read and honour.

`cap papercut` should take a subject and refuse an entry that names a project,
the way `cap spawn` refuses a duplicate pane. Then the markdown is generated,
the way map.md already is.

## Cross-cutting, not blocked on any stage

- `cap ask` must install the ownership guard when `--dir` points at a task
  worktree. It does not today, so `cap cleanup` and `cap commit` run unguarded
  agents inside a partitioned tree. Caught on cap-headless, where the cleanup
  pass edited a file outside the task's `--owns` and would have carried a stale
  copy of a deleted block back through the merge.
- Spawn preflight. Sixteen of sixty-nine mined tool failures are an agent
  discovering the worktree lacks something the task obviously needed. A
  worktree the project cannot build in is not ready, and telling the agent to
  start anyway spends a session finding that out one failed turn at a time.
  Blocked only by file ownership while stage 2 holds `lib.sh`.
- `cap-ask`'s claude branch is one inline block of about 170 lines covering
  resume-key resolution, the turn loop, result parsing, session-limit
  classification, usage recording and error reporting, and the harness dispatch
  is three top-level `if ... exit 0` blocks rather than one `case`, so the set
  of supported harnesses is no longer stated in one place. Raised by Gate A at
  round ten of cap-headless and deliberately not acted on there: restructuring
  the file at that point was the surest way to add a defect to a branch that
  had spent ten rounds removing them. It belongs to whoever next opens that
  file, which is the stage 3 spawn work.
- `cap doctor`. Comparing two Captain hosts took a dozen manual ssh probes.
- Locking. `task_lock` exists and only `cap gate`, `cap check`, `cap drop`,
  `cap land` and `cap cleanup` take it. Three captain sessions share this hub
  right now and the prompt hook says so every turn.

## Not in this plan

Rewriting anything above the transport line. Replacing herdr, which is the
right tool for attaching to a session a human wants to watch. Touching the
role and tier model. Reformatting bin/ with shfmt, which would rewrite 1828
lines and teach everyone to ignore the diff.

## How to know the plan is working

The signal is already in NORTH.md: paper-cuts.md gets shorter over time, and
review findings decrease as gates improve. Add one. The share of Captain's own
paper cuts whose root cause is transport or substrate was ten of nineteen on
the day this was written. If stages 2 and 5 are right, that share falls and
does not come back.
