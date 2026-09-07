# Brief: Verbatim - Phase 4 (interview coaching layer)

## Context

Phases 0-3 (all landed on `master`) built capture, transcript review with
line-level annotations, and a spaced-repetition study loop built on those
annotations. This phase adds a second, separate feedback layer specific to
the mock-interview portion of a lesson - the part where David asks a
software-engineering interview question and the student answers at length,
as opposed to the casual-conversation portion annotations already cover.

Read `notes/verbatim/spec.md`'s Phase 4 section. Read
`packages/convex/convex/schema.ts` and `annotations.ts` before designing
anything - **the existing `annotations.type` union already has literals
named `interview-structure` and `technical`**, added in Phase 0 for
line-level, single-note feedback. Do not treat those as already solving
this phase. This phase's rubric feedback is scored per interview *segment*
(a run of transcript lines answering one question), not per line or word
range, and the brief's own framing is explicit: keep it "distinct from
pronunciation/grammar notes, not merged into them." Design a real,
separate data shape for segment-level rubric feedback - don't just point
existing annotations at a range and call it done. If after real
consideration you think reusing/extending the annotation type is
genuinely better than a new table, make that case in your report rather
than defaulting to it because it's less work.

## What "done" looks like

Three connected pieces, all reachable from the website (no extension
changes):

### 1. Interview question bank

A `interviewQuestions` table (schema addition - topic, difficulty, prompt
text, tags) and a management surface for it. David is the only one asking
interview questions in this product, so authoring the bank is tutor-only -
gate writes on `role === "tutor"`, same pattern as existing tutor/student
role checks elsewhere in this codebase (check how pairing/consent already
gate on role before inventing a new pattern). A simple list + create/edit
form is enough; this is content management, not a novel UI problem.

### 2. Tying a lesson segment to a question

On the existing session review page
(`apps/web/src/app/dashboard/sessions/[sessionId]/`), let the tutor select
a range of transcript lines (reuse whatever line-selection primitive
`text-range.ts`/the annotation flow already established, extended to a
line range instead of a char range within one line) and tag it with a
question from the bank. Store this as its own record (sessionId, questionId,
starting/ending transcript line, or line-order bounds) - a new table,
your call on exact shape (e.g. `interviewSegments`).

### 3. Rubric-based feedback on a segment

For a tagged segment, let the tutor record rubric feedback across the
specific dimensions the brief names: answer structure, concise framing,
trade-off discussion, technical vocabulary. Research whether a fixed
four-dimension shape (each dimension gets a short note, and/or a simple
scale - your call whether a numeric/qualitative rating adds real value
here or just adds friction for a two-person product with no aggregate
scoring downstream yet) serves this better than a free-form list, given
what Phase 5's automated scoring will eventually need to slot into. Keep
it structured enough that a later phase's UI can render "structure: ...,
conciseness: ..., trade-offs: ..., vocabulary: ..." predictably, not a
single opaque text blob.

Surface tagged segments and their rubric feedback somewhere sensible on
the review page - a new tab alongside the existing Transcript/Notes tabs
is the obvious fit given `detail-view.tsx`'s existing tab structure, but
use your judgment.

## Testing

Same policy as every phase: no automated test suites, verify everything
possible against the real deployment (seed real questions, a real session
with a segment tagged and rubric feedback attached, walk through every
mutation's validation and ownership-check path the way every prior phase
has), and say plainly what needs a human with a browser. This phase is
lower browser-risk than 1-3 (no new media capture), so the human-needed
list should be short - mostly interaction/layout, not correctness.

## Out of scope for this phase (do not build)

- Automated pronunciation scoring or any external ML worker - Phase 5.
- Tying rubric feedback into the spaced-repetition queue - Phase 3's
  `reviewCards` are annotation-sourced; leave that as is unless you find a
  concrete reason a rubric item belongs there too (say so if you do,
  don't just add it).
- Any change to the extension or capture pipeline.
