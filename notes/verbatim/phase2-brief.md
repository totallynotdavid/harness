# Brief: Verbatim - Phase 2 (review UI)

## Context

Phase 1 (landed on `master`, both halves) built capture: a WXT MV3 extension
records Google Meet captions and audio and uploads them to Convex. A
`lessonSessions` row ends with `status: "ready"`, an `audioStorageId` +
`audioDurationMs` + `audioOffsetMs`, and its `transcriptLines` (`speakerId`
or `speakerLabel`, `text`, `startMs`, `endMs`, `order`) on the same clock as
the audio (seek a line's audio with `startMs - audioOffsetMs`). None of this
has a real Meet call behind it yet - there's no browser on the build
machine, so everything so far is verified against the real Convex deployment
with stubbed browser/media APIs. This phase is pure website work and needs
no browser extension changes at all, so it isn't blocked by that gap.

Read `notes/verbatim/spec.md` for the full architecture and the "UI reuse
from reloop" section - it names specific reloop files to adapt rather than
design from scratch. Read `packages/convex/convex/schema.ts` (already has
`annotations` and `reviewCards` tables from Phase 0, unused until now) and
`apps/web/src/app/dashboard/page.tsx` (currently an empty-state placeholder
- this phase replaces its guts, not its route).

## What "done" looks like

A tutor signs in, lands on `/dashboard`, sees their past lesson sessions
listed with status, opens one, and gets:
- The full transcript as a scrollable, speaker-grouped conversation - not
  Meet's two-line window.
- Click any line, hear that moment: `[startMs - padding, endMs + padding]`
  from the session's audio file (apply `audioOffsetMs`), playback stops
  automatically at the end of the clip. Prev/next-utterance controls to walk
  through the recording line by line without hunting for a scrubber
  position.
- Select a line (or a word range within one) and attach a typed annotation
  (`pronunciation` | `grammar` | `word-choice` | `filler` |
  `interview-structure` | `technical`) with a free-text note. Annotations
  persist to the `annotations` table and show inline against the line they
  belong to.

`reviewCards` (spaced-repetition state) is schema-ready but **out of
scope** - Phase 3 owns turning annotations into review cards and the study
loop that consumes them. Don't build anything that writes to that table.

## UI reuse - adapt these, don't design from scratch

Per `notes/verbatim/spec.md`'s "UI reuse from reloop" section, pull the
actual source of these via `gh` from `reloop-labs/reloop`,
`apps/frontend/web`, and adapt them into `packages/ui`:
- `src/app/contact/support-chat.tsx` - the transcript stream: scrollable
  `role="log"`, speaker-grouped bubbles, mono timestamps, jump-to-latest.
- `src/app/(home)/components/email-analytics/preview-stage.tsx` - main
  content + side panel composition; the transcript pane is the main content,
  the notes/audio panel is the side panel.
- `src/app/(home)/components/emails/detail/email-detail.tsx` - detail
  header and tabbed content views; map its tabs to Transcript / Notes.
- `packages/ui/src/components/tab-menu-horizontal.tsx`,
  `status-badge.tsx`, `badge.tsx` - tabs and session-status treatment
  (`recording` / `processing` / `ready` / `incomplete`).
- `packages/tailwind/style.css` - confirm the design tokens already ported
  into `packages/ui` in Phase 0 still match; this phase is the first to
  build UI dense enough (annotation popovers, audio controls) that gaps in
  the token port would start to show.

Match reloop's visual language - don't reinvent a different look for this
phase's new surfaces.

## Audio playback - the real technical question

`HTMLAudioElement` playing a single-file WebM/Opus recording, seeking to
`(startMs - audioOffsetMs - padding) / 1000` on click and using a
`timeupdate` listener (or a `setTimeout` sized to the clip length) to pause
at the end - verify which is more reliable for a short clip in the browsers
you're targeting; Context7/current MDN docs and real examples over
assumption, same standard as Phase 1. Decide on a padding value (e.g.
150-300ms each side) and say what you picked and why. Fetch the audio file
once per session (a signed URL from `ctx.storage.getUrl` or similar, check
Context7 for the current Convex API) rather than re-fetching per line click.

## Convex functions needed

- A session-list query for the current pairing (`lessonSessions` +
  status), replacing the dashboard's current empty-state-only body.
- A single-session query returning the session, its ordered
  `transcriptLines`, and its `annotations` (joined or in one round trip -
  your call).
- `annotations.create` (sessionId, transcriptLineId, type, note) - author
  is the caller; check the caller is one of the session's tutor/student
  pair, same ownership pattern as `lessonSessions`'s `requireOwnSession`
  helper (reuse or mirror it, your judgment - `transcriptLines.ts` already
  has its own copy from Phase 1, so this is already a repeated pattern, not
  a new one).
- `annotations.delete` or `annotations.update`, if the UI lets a tutor
  correct/remove a note - your call whether v1 needs edit or just
  create+delete.

## Testing

Same policy as Phase 1: no automated test suites (still moving shape). This
phase, unlike Phase 1, needs zero browser-extension work - but it's still a
UI-heavy phase on a machine with no display. Do what you can headlessly
(Convex function checks against the real deployment with real data seeded
via the CLI or a script; component logic you can exercise outside a
browser), and say plainly what still needs a human clicking around in an
actual browser - this phase will need much more of that than Phase 1's
backend-heavy work did, since the whole point is visual/interactive
(scrolling, clicking a line, hearing the right clip, placing an annotation).
Don't claim more confidence than a no-browser environment can earn for a UI
phase like this one.

## Out of scope for this phase (do not build)

- `reviewCards` / spaced repetition / any study loop - Phase 3.
- Interview-question bank or coaching features - Phase 4.
- Automated pronunciation scoring - Phase 5.
- Any change to the extension or capture pipeline.
- Multi-session bulk actions, export, or sharing.
