---
name: loop
description: Take a shaped piece of work to landable - build, check, simplify, prove, summarise - with evidence a human can verify in seconds. Use to run a task end to end once the approach is settled.
---

# Loop

Five steps, each with an artifact. A step with no artifact did not run.

## 0. Pick the mode

**MVP**: personal, exploratory, cheap to discard: make the obvious calls, build the
smallest demonstrable thing, skip steps 2 and 3, and decide afterwards whether it
graduates. **Spec**: the captain owns the consequences: run all five.

Choosing wrong is expensive in both directions. Say which one you picked.

**Complete when:** the mode is named.

## 1. Build

An agent builds it in its own worktree (`crew` skill). This session supervises with
`cap watch` and does not write project code.

**Complete when:** the branch carries commits and `cap crew` shows the task idle.

## 2. Check, then review

`cap check <slug>` first. It is cheap and deterministic within its defined patterns. Then the `review`
skill for what judgment is actually needed.

**Complete when:** deterministic findings are fixed or acknowledged, and each review
finding is verified against the code before it is acted on.

## 3. Simplify

Fixes stack into patches on patches and the shape drifts. Cut back to the same behaviour
with less code and fewer branches; delete what the fixes made dead.

Behaviour is frozen here. A behaviour change you want is a new task, not a simplification.
Consolidate a test only after proving another test guards the same defect at the same
boundary: count invariants, not files. Then read `rules/code.md` against the diff.

Stop instead of forcing the metric when shrinking would delete a unique invariant, raise
coupling, or need authority beyond the task.

**Complete when:** the tree is smaller, every invariant still has a guard, and the tests
pass.

## 4. Prove

Tests cover the cases you thought of. Pick what fits:

- **visible** -> before/after screenshot, or a gif if it moves
- **measurable** -> a benchmark on both sides of the change
- **concurrent, stateful, or failure-prone** -> hammer it: parallel runs, killed
  mid-flight, dependencies pulled out from under it

Drive the real surface, not the test suite. No evidence means not proven: say that
plainly rather than asserting it works.

**Complete when:** the claim has evidence at its own layer, or the gap is named.

## 5. Land and summarise

`cap land <slug>`, then write `notes/<project>/<slug>.md`: behaviour change, architecture
change, the evidence from step 4, and the follow-ups you deliberately left. Every solution
defers a tradeoff: name it.

When the captain will act on it or share it, publish it as an Artifact and hand over the
link rather than leaving it in scrollback.

Then `record-case` if anything surprised you.

**Complete when:** the work is landed or the refusal is reported, and the summary names
its deferred tradeoff.
