# Attribute cost per dispatch, and stop re-reviewing what already passed

Five changes. Sections 3 and 5 depend on nothing else here and land first.
Sections 1, 2 and 4 depend on `interactive-dispatch.md` landing first: it
removes the `stream-json` parsing that section 1 would otherwise be built on,
and section 2's concurrency and section 4's `--effort` wiring both belong in
the dispatch path that brief replaces, not the one it deletes.

## 1. Record what each dispatch cost

`bin/cap-ask` parses `stream-json` and keeps only the last `rate_limit_event`
of a turn. The stream carries one every few seconds, so a single dispatch's own
share of the 5h window is the difference between the first and the last:

    utilization: 0.32 0.33 0.34 0.35 0.36 0.37   <- one gate-a run

Each `assistant` event also carries `message.usage` with `input_tokens`,
`output_tokens`, `cache_creation_input_tokens` and `cache_read_input_tokens`.

Keep the first `rate_limit_event` alongside the last, and sum `message.usage`
across the turn. Write both against the dispatch that `dispatch_log` already
records, so `state/usage/dispatch.log` carries the cost of each call and not
only the account reading it started at.

The window delta is account-wide: anything else running on any machine during
the same turn is inside it. The token sum is exact. Report both and label which
is which. Do not present the delta as this dispatch's consumption.

`cap budget` then shows cost per dispatch, so the expensive stage can be found.

## 2. Run gate A and gate B concurrently

`bin/cap-gate` iterates its profiles in a `for` loop, so gate B does not start
until gate A has finished. Measured across five rounds:

    round    A done   B done   B starts after A
    22        12.7m    24.1m        +11.4m
    26        12.8m    19.5m         +6.8m

    total gate wall clock, 5 rounds: 110 min
    if A and B ran concurrently:      65 min

Both profiles are already resolved before the loop, so no sizing decision
depends on one finishing before the other starts. Dispatch both, wait for both,
then record the verdicts in `gate.json` in order - that write is the only part
that has to stay serial.

## 3. Gate the increment, not the whole branch

`cap gate` reviews `CAP_BASE..HEAD` every round. On a task at round 24 that is
70 commits and 21 files re-reviewed from scratch, including machinery that
passed unchanged in round 22 and was never touched again.

`gate.json` already stores a per-profile fingerprint. Store the commit each
profile last returned PASS at, and review from there instead of from the base.
`cap gate --full` keeps the whole-branch review, and `cap land` requires a
`--full` verdict, so nothing lands on an increment-only review.

## 4. Choose a reasoning effort for the claude profiles

`config/captain.conf` pins every codex profile at `xhigh` and leaves every
claude profile at `-`, the harness default. `bin/cap-spawn` passes `--effort`
only when one is set, so crew, both gates and the commit agent run at whatever
the CLI defaults to.

Set it per role rather than per profile. The heavy tier's judgment has to be
right the first time; the cheap tier writes commit messages.

## 5. Three checks for defect classes the gates keep re-finding

`bin/lint-andlist` is the shape to follow: one mechanical signature, wired into
`mise`, failing before a gate is dispatched. Each of these has already cost a
review round.

- A `while ... done < <(cmd)` whose producer can fail invisibly. Zero
  iterations reads exactly like a clean result, so a guard built this way
  reports clean when it could not run. Six sites in `bin/`.
- `git rev-list --reverse` used to order a rewrite without `--topo-order`. It
  emits a side branch before the commit it forked from, so a parent lookup
  built in traversal order is incomplete whenever a merge is in range.
- A flag parsed into a variable that some branch never reads, so the flag is
  accepted and silently dropped.
