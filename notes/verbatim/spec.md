# Verbatim - architecture and requirements

Working name: **verbatim**. Rename freely; nothing below depends on the name.

## Product

A tutor runs 1:1 English lessons over Google Meet with a Spanish-speaking
student preparing for software engineering job interviews. Lessons mix
casual conversation and mock interviews. Verbatim captures each lesson's
transcript and audio, then gives both people a review surface: read the full
conversation (not Meet's two-line caption window), click any sentence to
hear exactly how it was said, annotate mispronunciations and rough spots,
and build a study queue from real lesson evidence instead of generic drills.

This is a production system built in passes, not an MVP. Each phase below is
a complete, usable slice - not a throwaway prototype.

## Architecture decisions

### Extension + website, not extension-only

The extension's only job is capture: it runs on `meet.google.com`, has
almost no UI, and uploads transcript lines + audio to the backend. Every
review, annotation, study, and trend feature lives in the website. Reasons:

- Popup/side-panel real estate cannot hold a transcript + audio player +
  annotation UI worth using daily.
- The student should be able to review a lesson from a phone or a laptop
  without the extension installed.
- Consent management, account settings, cross-lesson history, and sharing a
  clip link are website concerns, not in-page-overlay concerns.
- It mirrors reloop's own split (marketing/dashboard web app separate from
  where the actual product surface lives), which is also where we're
  borrowing UI language from - see "UI reuse" below.

### Website stack

- **Next.js (App Router) + React + TypeScript.** Matches reloop, so
  components can be adapted rather than reimagined.
- **Tailwind CSS 4**, CSS-first config (no `tailwind.config`), same as
  reloop.
- **Local `packages/ui`**: Radix primitives + `tailwind-variants` + `cva` +
  `tailwind-merge`, the same combination reloop's `@reloop/ui` uses. Build
  this rather than adopting shadcn wholesale, so the visual language can
  match reloop's tokens exactly instead of approximating them.
- **Framer Motion** for transitions, **`next-themes`** for dark mode.
- **Bun workspaces + Turborepo** for the monorepo, matching reloop's
  tooling.

### Backend: Convex

One platform for database, file storage, serverless functions, scheduled
jobs, and realtime queries, instead of hand-assembling Postgres + S3 + a
cron runner + a websocket layer:

- Reactive queries fit this product directly: a lesson's processing status
  updates live in the UI as the extension uploads it, and an annotation the
  tutor adds appears for the student without a manual refresh.
- File storage handles lesson audio without a separate object-storage
  integration. `ctx.storage.generateUploadUrl()` accepts arbitrarily large
  uploads (the 20MB cap is only on the alternate HTTP-action upload path,
  which this product does not need) - confirmed against current Convex
  docs, not assumed. A lesson-length Opus recording is tens of MB, well
  inside plan storage quotas.
- Scheduled functions cover spaced-repetition due-date computation and
  nightly trend rollups without an external job runner.
- Convex actions can call an external HTTP worker later (WhisperX,
  OpenPronounce) for phases 5+, so this doesn't box the product out of
  heavier ML work - it just doesn't run inside Convex's own runtime.

If a lesson archive eventually outgrows Convex storage economics, the `@get-convex/r2`
component is a documented escape hatch that keeps the same
`ctx.storage`-shaped API while moving bytes to Cloudflare R2. Not needed at
launch; noted so a later pass doesn't have to rediscover it.

### Auth: Convex Auth, Google OAuth only

Confirmed against current Convex Auth docs: Google is a first-class
provider (`@auth/core/providers/google`), configured directly in
`convex/auth.ts`. Both tutor and student already have Google accounts
because they use Google Meet, so Google sign-in is the natural (and only,
at launch) sign-in method - no password reset flow, no email delivery
pipeline to build or operate. The extension authenticates by opening the
website's OAuth flow and sharing the resulting session back via
`chrome.storage` + runtime messaging; it does not run its own OAuth flow.

Do not build custom password auth. It adds a real security surface
(hashing, reset tokens, session fixation, credential stuffing) for zero
product benefit here, since the entire user base already has Google
accounts and already uses a Google product to take the lesson.

### Extension stack

- **MV3, TypeScript**, bundled with Vite via `@samrum/vite-plugin-web-extension`
  (or CRXJS - pick either when scaffolding; both handle MV3's
  content-script/service-worker/offscreen-document split, unlike a bare
  Vite build).
- **Content script** on `https://meet.google.com/*`: MutationObserver on the
  captions region, tracking a per-row draft (speaker, text, first-seen
  timestamp, last-change timestamp), finalizing a transcript line once a row
  settles. This mechanism is already validated by prior research in this
  repo (`notes/captain` session history) and by existing projects
  (transcriptonic, capcopy) using the same technique.
- **Offscreen document + `chrome.tabCapture`**: records the Meet tab's
  audio. Mix in the tutor's own microphone via `getUserMedia()` through
  `AudioContext.createMediaStreamDestination()` so both voices land in one
  recording, since a 1:1 lesson doesn't need independently isolated tracks
  at launch.
- **Service worker**: session lifecycle (start/stop recording), the auth
  bridge described above, and the upload coordinator - flushing transcript
  lines and audio chunks to Convex periodically during the call, not only
  at the end, so a crash or tab close doesn't lose the whole lesson.
- The extension never slices per-sentence audio files itself. It uploads
  one continuous audio file plus each line's `startMs`/`endMs`. The website
  derives playback clips on demand (seek-and-stop on the shared file,
  padded by a configurable margin before/after each line - caption
  timestamps mark ASR/UI timing, not exact speech boundaries).

### Consent, as a first-class requirement, not a footnote

Recording a call with another participant has real consent-law
implications (jurisdiction-dependent; Meet's own recording notice does not
cover a tab-capture extension recording independently). Phase 0 includes an
explicit consent step: both accounts must record consent before a session
can start recording, consent state is stored per session, and withdrawing
consent stops recording. This is a product requirement, not an
implementation detail to add later.

## Data model (Convex schema, initial shape)

- `users` - id, googleSub, name, email, role (`tutor` | `student`), pairing
  (which tutor/student they're linked to - single pair at launch, see
  "Explicitly deferred").
- `lessonSessions` - tutorId, studentId, startedAt, endedAt, status
  (`recording` | `processing` | `ready` | `incomplete`), audioStorageId,
  audioDurationMs, consentTutor, consentStudent.
- `transcriptLines` - sessionId, speakerId, text (raw ASR from Meet
  captions), startMs, endMs, order.
- `annotations` - sessionId, transcriptLineId (or a word-range within one),
  type (`pronunciation` | `grammar` | `word-choice` | `filler` |
  `interview-structure` | `technical`), note, authorId, createdAt.
- `reviewCards` - derived from annotations, sessionId, sourceAnnotationId,
  dueAt, interval, ease (spaced-repetition state).
- `interviewQuestions` (phase 4) - topic, difficulty, prompt, tags.

Keep every transcript line's raw ASR text immutable once written. Corrected
or "natural English" rewrites are separate fields or a separate layer, never
an overwrite - the tutor needs to see what was actually captured, not just
the cleaned-up version.

## UI reuse from reloop (`reloop-labs/reloop`, `apps/frontend/web`)

Already surveyed; concrete files to adapt rather than design from scratch:

- `src/app/contact/support-chat.tsx` - closest model for transcript rows:
  scrollable `role="log"` stream, speaker-grouped bubbles, mono timestamps,
  "jump to latest."
- `src/app/(home)/components/email-analytics/preview-stage.tsx` - main
  content + side panel composition, the right shape for transcript pane +
  notes/audio panel.
- `src/app/(home)/components/emails/detail/timeline.tsx` - status-milestone
  timeline language, reusable for a lesson's event history.
- `src/app/(home)/components/emails/detail/email-detail.tsx` - detail
  header, tabbed content views (map to Transcript / Audio / Notes /
  Insights tabs).
- `packages/tailwind/style.css` - the actual design tokens (color,
  typography, spacing, dark-mode) to port wholesale rather than reinvent.
- `packages/ui/src/components/tab-menu-horizontal.tsx`,
  `status-badge.tsx`, `badge.tsx`, `vertical-stepper.tsx` - reusable
  primitives for tabs and status treatment (processing/reviewed/flagged).

## Repo layout (once scaffolded)

```
verbatim/
  apps/
    web/          # Next.js website (the product surface)
    extension/    # MV3 extension (capture only)
  packages/
    ui/           # shared component library, reloop-styled
    convex/       # Convex schema + functions, shared by web and extension
```

## Testing policy for now

Do not add automated test suites yet. The data model, capture pipeline, and
UI are all going to change shape across the first several passes, and tests
written against a moving target are pure maintenance cost. Verify each
phase manually (a real Meet call for capture, a real browser session for
review UI). Revisit automated testing once the core flows - capture,
transcript storage, playback - stop changing shape.

## Phased roadmap

Each phase is a complete brief-sized unit of work for `cap spawn`. Land and
verify one phase before starting the next; later phases assume earlier ones
work.

### Phase 0 - Foundation
- Scaffold the monorepo (Bun + Turborepo, the layout above).
- Convex project: schema above, Convex Auth with Google provider wired up
  for the website.
- Website: sign-in flow, empty dashboard shell using reloop's design tokens
  and layout shell (sidebar, header, theme toggle).
- Consent data model and the consent UI step (both parties must consent
  before a session can be marked recordable).
- No extension yet. No transcript/audio features yet. Goal: a deployed,
  authenticated, empty product.

### Phase 1 - Capture
- Extension scaffold (MV3, content script, offscreen document, service
  worker) per "Extension stack" above.
- Caption MutationObserver + per-row draft tracking, finalized transcript
  lines.
- `chrome.tabCapture` + mic mix, continuous recording via `MediaRecorder`.
- Upload pipeline: periodic flush of transcript lines and audio chunks to
  Convex during the call; session finalization on call end.
- Auth bridge from extension to the website's Convex Auth session.
- Verify against a real Meet call end-to-end: start recording, talk,
  captions on, stop, confirm the full transcript and one playable audio
  file land in Convex.

### Phase 2 - Review UI
- Website transcript viewer: full scrollable conversation (not Meet's
  two-line window), speaker-grouped, using the support-chat-derived
  component.
- Per-sentence audio playback: click a line, hear
  `[startMs - padding, endMs + padding]` from the shared audio file, stop
  automatically. Prev/next-utterance controls.
- Annotation UI: select a line or word range, attach a typed note
  (pronunciation/grammar/word-choice/filler/interview-structure/technical).
- Session list/dashboard (the reused email-list pattern) showing past
  lessons with status.

### Phase 3 - Study loop
- Spaced-repetition queue built from annotations (`reviewCards`): due-date
  scheduling via a Convex scheduled function, a "review today's clips" UI.
- Retry-recording flow: student records a retry for a flagged
  sentence/word, original and retry play side by side.
- Cross-lesson trend view: recurring flagged sounds/words, filler rate,
  words-per-minute, over time.

### Phase 4 - Interview coaching layer
- `interviewQuestions` bank tagged by topic/difficulty (system design,
  algorithms, behavioral, etc.).
- Tie mock-interview segments of a lesson to specific questions.
- Rubric-based feedback surface alongside language annotations: answer
  structure, concise framing, trade-off discussion, technical vocabulary -
  distinct from pronunciation/grammar notes, not merged into them.

### Phase 5 - Automated pronunciation scoring
- External worker (outside Convex's runtime) running WhisperX and/or
  OpenPronounce, invoked from a Convex action.
- Auto-flag low-confidence words and phoneme-level mispronunciations as
  draft annotations the tutor confirms or dismisses, rather than
  auto-publishing model output as fact.

## Explicitly deferred (not phases yet, don't build for these now)

- Multiple students per tutor, or multiple tutors - the data model above
  assumes one active pairing; widening it is a schema change to make
  deliberately, not something to speculatively generalize for now.
- Non-Google sign-in.
- Mobile app (the website should be responsive enough to use on a phone
  browser; a native app is not planned).
- Billing/subscriptions.
- Any other video-call platform besides Google Meet.

## Prior art consulted

Full detail in this repo's Codex session history (see `cap history --repo
captain`); summarized here so a future pass doesn't need to re-search:

- **tracet** (`theagitist/tracet`) - closest existing match for exact
  per-sentence audio playback via WhisperX alignment. Local macOS app, not
  a Meet extension; useful for its data model, not reusable as code.
- **transcriptonic** (`vivek-nexus/transcriptonic`) - Meet caption capture
  as an MV3 extension, no audio. Useful reference for the capture side.
- **OpenPronounce** (`Halleck45/OpenPronounce`) - CPU-capable phoneme-level
  pronunciation scoring against expected text. Candidate for phase 5.
- **WhisperX** (`m-bain/whisperX`) - word-level timestamps + diarization.
  Candidate foundation if phase 5 needs re-alignment beyond Meet's own
  captions.
- No existing open-source project combines Meet capture + full-transcript
  review + per-sentence audio + tutor annotation + interview coaching.
  Building it is the right call.
