# Brief: Verbatim - Phase 3 (study loop)

## Context

Phases 0-2 (all landed on `master`) built: capture (captions + audio,
extension), and review (transcript viewer, per-sentence playback,
annotations). A tutor can now open a lesson and attach a typed annotation
(`pronunciation` | `grammar` | `word-choice` | `filler` |
`interview-structure` | `technical`, optionally scoped to a word range via
`charStart`/`charEnd`) to a transcript line. `annotations.create` exists in
`packages/convex/convex/annotations.ts`; the `reviewCards` table exists in
schema but nothing writes to it yet - Phase 2's brief explicitly deferred
that to this phase.

Read `notes/verbatim/spec.md`'s Phase 3 section and its "UI reuse from
reloop" section (the same reloop-adapted primitives from Phase 2 -
`packages/ui` - are yours to keep extending, not to duplicate). None of
Phase 1 or 2 has been verified in a real browser yet (no display on this
build machine, same as every phase so far) - keep doing what Phase 1/2 did:
verify everything possible against the real Convex deployment and real
component rendering, and say plainly what still needs a human.

## What "done" looks like

Three connected pieces:

### 1. Spaced-repetition queue

Every new annotation gets a `reviewCards` row (`dueAt`, `interval`, `ease`)
- decide whether `annotations.create` itself writes it or a separate step
does; either is fine, avoid two mutations where a tutor expects one action
to produce one queue entry. Research a real spaced-repetition scheduling
algorithm (SM-2 is the standard starting point - look at real
implementations, not just the Wikipedia summary) rather than inventing
interval math from scratch. A "Review" surface (new route or a dashboard
section - your call) lists today's due cards across all the tutor/student
pair's sessions, each showing the flagged transcript line, its annotation
note, and a way to play the original clip (reuse `use-clip-player.ts`,
`clip.ts` - don't rebuild clip-window math). Reviewing a card (however you
define "reviewing" - hearing it, or completing the retry flow below) updates
its `dueAt`/`interval`/`ease` per whatever algorithm you picked.

### 2. Retry-recording flow

For a pronunciation-type card in particular (but don't hard-block other
types if a retry makes sense for them - your judgment), the student records
themselves saying the flagged word/sentence and plays it back next to the
original clip. This is **new microphone capture from the website itself**,
not the extension - `getUserMedia({audio: true})` + `MediaRecorder` in a
browser tab, nothing to do with Meet or `tabCapture`. Store each retry as
its own short recording (a new table - `retryRecordings` or similar:
reviewCardId or annotationId, storageId, createdAt, durationMs - schema
addition needed) rather than trying to splice it into a lesson's audio.

**Serve retry audio the same way lesson audio is served** -
`packages/convex/convex/http.ts` already has an authenticated route for
lesson audio (`/lessonAudio`, added in Phase 2 specifically because
`ctx.storage.getUrl()` is a permanent public link and this product treats
recording privacy as a first-class requirement). Extend that pattern for
retry recordings rather than reintroducing a public URL for them - short
personal pronunciation clips deserve the same treatment as lesson
recordings, not less. If the ownership-check logic in
`packages/convex/convex/model/sessions.ts` doesn't cleanly cover a
reviewCard/annotation-scoped resource, factor what's shared rather than
copying the whole check a third time.

### 3. Cross-lesson trend view

A view (dashboard section or its own route) surfacing patterns across a
pair's full lesson history: recurring flagged words/sounds (group
annotations by the underlined text - use `charStart`/`charEnd` against the
parent `transcriptLines.text` where present, falling back to the note text
where a range wasn't set), filler-annotation rate over time, and
words-per-minute per session (transcript word count over
`endedAt - startedAt`, or over the last line's `endMs` if that's a tighter
measure - your call, document which and why). This is read-only aggregation
- no new capture, no new write paths beyond what parts 1-2 already added.

## Testing

Same policy as every phase so far: no automated test suites, verify
everything possible against the real deployment (seed real sessions,
annotations, and reviewCards the way Phase 2 seeded a lesson to click
through), and say plainly what needs a human with a browser - this phase
adds a second real-microphone-capture surface (the retry flow) on top of
Phase 2's real-audio-playback surface, so the human-verification list is
likely to grow, not shrink. Update `SETUP.md` with whatever a person needs
to do to exercise the review queue and retry flow.

## Out of scope for this phase (do not build)

- Interview-question bank or coaching rubric - Phase 4.
- Automated pronunciation scoring / phoneme-level analysis - Phase 5. The
  retry flow here is playback-for-human-comparison only; no scoring model.
- Any change to the extension or the Meet capture pipeline.
- Multi-student support, sharing, or export.
