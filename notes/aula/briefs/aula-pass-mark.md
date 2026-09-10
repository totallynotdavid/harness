# aula-pass-mark: 13 out of 20 is a pass

You own `layers/courses/` and the single file
`layers/issuance/server/utils/has-passing-grade.ts`. Nothing else.

## Why

CICAT's pass mark is **13 on the 0 to 20 scale**. The captain confirmed it.

Nothing in the codebase knows this. `layers/courses` stores a raw integer
score and defines `GRADE_SCALE_MAX = 20`, but no minimum. When
`layers/issuance` needed to decide whether a student had passed, it found no
threshold to consult and settled for "a grade row exists", which releases a
certificate to a student who scored 3.

`has-passing-grade.ts` says so in its own header, and says the threshold
belongs in `layers/courses` as that layer's decision. That is what you are
implementing.

## Deliverable 1: the threshold, in courses

Define the pass mark next to `GRADE_SCALE_MAX` in
`layers/courses/shared/grade-to-words.ts`, or somewhere better in that
layer's `shared/` if you can justify it. It is part of the layer's public
surface, because another layer has to read it.

Name it so a reader cannot mistake it for a maximum or a percentage, and
state the scale in the name or immediately beside it. `13` on its own in a
comparison somewhere is how this gets misread later.

Add whatever predicate makes the comparison read well at the call sites
(`isPassing(score)` or similar) rather than exporting a bare number that
every caller re-implements a `>=` against.

## Deliverable 2: issuance consumes it

`hasPassingGrade` currently returns true when a `grade` row exists. It must
return true only when the captured score meets the pass mark. Import the
threshold from `layers/courses/shared/`, which is that layer's public
surface. Do not redefine 13 inside `layers/issuance`.

Replace the header comment. It documents the absence of a threshold, and
that absence is what you are removing.

## Deliverable 3: say so where it matters

Wherever `layers/courses` shows a captured grade to a teacher or a student,
a score below the pass mark should be visibly a failure, not just a number.
Use the existing design system semantics rather than inventing a colour.

Check `grade-to-words.ts` while you are there: if it renders a score as
words, the wording should not imply a pass for a failing score.

## Tests

The boundary is the whole point. Test 12, 13 and 14 explicitly, plus 0 and
20. A test that only checks 5 and 18 would pass against an off-by-one
threshold, which is the defect most likely to survive this change.

Update `layers/issuance`'s existing tests for the new behaviour: a student
with a captured score below 13 must not be releasable.

## Verify

`pnpm test`, `pnpm lint`, `pnpm typecheck`, `pnpm build`, plus a direct check
against seeded data. `pnpm db:seed` creates a graded student; confirm the
release path behaves correctly on both sides of 13.
