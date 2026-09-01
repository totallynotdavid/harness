---
name: record-case
description: Close the learning loop after a task - record what happened as evidence, and when a human caught what a gate should have caught, fix the gate. Use after a review finds a real defect, after a surprise, and at the end of non-trivial work.
---

# Record a case

The point is not documentation. It is that the same miss does not happen twice.

## 0. Is there a lesson

One issue, one mechanism, one transferable lesson. Split unrelated outcomes from the same
session; skip entirely when the work went as expected and taught nothing.

**Complete when:** the case is bounded, or skipped with a reason.

## 1. Ledger before prose

Write `cases/<project>/<date>-<slug>.md` with handles, not narrative: commit, branch, the
exact command and its output, the regression test and its fix-absent result, the review
decision. Grade every material claim per `rules/evidence.md`: evidence, report,
inference, or unknown.

**Complete when:** a reader can reconstruct the work from the handles without trusting the
narrative.

## 2. The question that matters

For every defect a *human* caught: **why did our gates not catch this?**

Then go find out: read the agent's own transcript and the diff; agent sessions are
files on disk and are greppable. One of three is true:

- **A gate could have caught it** -> change that gate. A surfaces line in
  `cases/<project>/conventions.md`, a check in `cap check`, a rule in `rules/code.md`, a
  constraint in the brief. Name the edit in the case.
- **No gate could have**: it needed context nobody had -> write that context into
  `notes/<project>/` where the next task will find it.
- **A gate caught it and was overruled** -> that is the finding. Record who overruled it
  and why before making anything stricter.

**Complete when:** the case names an edit, or names why no edit exists.

## 3. Keep the surface small

If the same fix keeps landing in the same place, it wants to be a skill. Most learnings do
not: they are a line in a note or an invariant in `conventions.md`. Prefer sharpening an
existing skill over adding one, and check the two rules for new checks in
`rules/evidence.md` before shipping any gate you just wrote.

**Complete when:** the smallest destination that holds the lesson was chosen.
