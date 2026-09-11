# aula-grade-test: the pass mark has no failing test

You own `layers/issuance/test` and nothing else.

## What is missing

`hasPassingGrade()` used to return true whenever a `grade` row existed. It now
compares the score against the pass mark of 13:

    return row !== undefined && isPassingGrade(row.score)

`layers/issuance/test/panel-emision.test.ts` covers two cases: a person graded
18, and a person with no grade at all. Both behave identically under the old
code and the new. Revert that line to `return row !== undefined` and the suite
still passes, so the fix is untested.

## Deliverable

Add the case that separates them: a person who is enrolled, graded, and below
13. Releasing their certificate must be refused with the same "passing grade"
error the ungraded person gets.

Add a case at exactly 13 as well. The boundary is the value the mark is, and
an off-by-one there is the likeliest way this breaks later.

Follow the fixture style already in the file. Do not change
`has-passing-grade.ts`, `grade-to-words.ts`, or any non-test file.

## Verify

Run `pnpm test`. Then prove the tests bite: temporarily change
`isPassingGrade` to return true, confirm your new cases fail, and put it back.
Report that you did this.
