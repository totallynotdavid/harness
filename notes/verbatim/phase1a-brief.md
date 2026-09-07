# Brief: Verbatim - Phase 1a (extension scaffold + caption capture + auth bridge)

## Context

Verbatim helps an English tutor and a Spanish-speaking student review their
Google Meet lessons: full transcript, per-sentence audio playback, tutor
annotations, spaced study. Phase 0 (already landed on `master`) built the
website: Next.js + Convex + Convex Auth (Google-only), a monorepo at
`apps/web` / `packages/ui` / `packages/convex`, sign-in, role selection,
invite-code pairing, an empty dashboard, and a consent data model. Verified
working end to end against a real Convex deployment.

This phase adds a browser extension that captures Google Meet's live
captions and uploads them to Convex as a transcript, tied to a real signed-in
user. **No audio in this phase** - that is Phase 1b, once this lands and is
verified. Do not build `chrome.tabCapture`, the offscreen document, or any
recording. This phase is about proving the capture -> auth -> upload path
end to end with text only.

## What "done" looks like

You join a real Google Meet call (solo is fine - a call with just yourself,
captions turned on, talking to yourself), click a "start lesson" control the
extension injects into the page, talk for a bit, click "stop," and the
finalized transcript lines show up in the `transcriptLines` table on the real
Convex dev deployment, attached to a `lessonSessions` record for the actual
signed-in user. Verify this yourself before reporting done - use
`bunx convex dashboard` or `bunx convex data transcriptLines` from
`packages/convex` to look at the deployment directly, the same one Phase 0
already configured (`.env.local` in `packages/convex` has
`CONVEX_DEPLOYMENT`/`CONVEX_URL` already set - you don't need to log in
again).

## Repo layout to add

```
apps/
  extension/    # new: MV3 extension
```

## Extension stack

- MV3, TypeScript, bundled with Vite. Use `@samrum/vite-plugin-web-extension`
  or CRXJS - either is fine, pick one and note why. Both handle MV3's
  content-script/service-worker split without hand-rolling a build.
- Content script matching `https://meet.google.com/*`.
- Service worker for message routing and calling Convex.
- No offscreen document in this phase (that's Phase 1b, for audio).

## Caption capture (content script)

This mechanism is already validated by prior research in this repo:

- Locate the captions region, preferring `[role="region"][aria-label="Captions"]`;
  keep a couple of older fallback selectors (`.nMcdL` for rows, `.NWpY1d` for
  speakers, `.ygicle`/`.VbkSUe` for text) as a backup since Meet's class names
  are unofficial and can shift.
- `MutationObserver` on `childList`, `subtree`, `characterData`, paired with a
  ~1s polling fallback.
- Track a per-row "draft" keyed by the DOM row element: speaker, current
  text, first-seen timestamp, last-change timestamp. When Meet edits a row's
  text (live-updating partial captions), update the draft instead of
  emitting a new line.
- Finalize a draft into a transcript line when its row disappears or stays
  unchanged for a short settle window (start around 1.5s, adjust if real
  testing shows it's wrong). Deduplicate rerenders.
- Ignore Meet's own UI chrome inside the captions region ("Jump to bottom,"
  toggle buttons, etc.), not just caption rows.
- Emit each finalized line (speaker, text, startMs, endMs, order) to the
  service worker via `chrome.runtime.sendMessage`.

Verify this against a real Meet call with captions on before wiring
anything else - confirm finalized lines in the console match what was
actually said, including a correction (Meet revises text as it disambiguates
speech) and a speaker change if you can arrange one.

## Auth bridge: extension needs to act as the real signed-in user

This is the one genuinely open design question in this phase - research it
properly, don't guess:

1. Use Context7 (`resolve-library-id` -> `query-docs`, library
   `@convex-dev/auth` / `/get-convex/convex-auth`) to find the current,
   correct way to retrieve a valid Convex Auth token from an authenticated
   browser session, and how to construct a Convex client elsewhere (e.g. a
   service worker) authenticated with that token
   (`ConvexHttpClient.setAuth` or equivalent - confirm the current API, don't
   assume).
2. A reasonable starting design, which you should validate rather than take
   on faith: add a protected page to the website, e.g. `/extension/connect`,
   that when loaded by a signed-in user, retrieves that user's current
   Convex Auth token client-side and hands it to the extension via
   `externally_connectable` in the extension's manifest (matching the
   website's origin) and `chrome.runtime.sendMessage(EXTENSION_ID, {...})`,
   received in the service worker via `chrome.runtime.onMessageExternal`.
   The service worker stores the token (`chrome.storage.local`) and uses it
   to build an authenticated Convex client for calling mutations directly
   from the extension.
3. Tokens expire. Figure out and document what the actual expiry/refresh
   behavior is for a token obtained this way, and handle it reasonably - at
   minimum, detect an auth failure when calling a mutation and prompt the
   user (via the extension's own UI) to revisit `/extension/connect` to
   refresh, rather than failing silently or crashing the capture session.
4. For local dev, the website runs at `http://localhost:3000` - use that as
   the `externally_connectable` origin for now; note in your final report
   that a production origin will need to be added later, don't try to guess
   or hardcode one.

## Convex functions to add

Phase 0 defined the `lessonSessions` and `transcriptLines` schema and a
`lessonSessions.startSession` mutation (consent-gated - both `consentTutor`
and `consentStudent` must be true, read fresh at call time). This phase
needs:

- A way to call `startSession` from the extension when the user clicks
  "start lesson" (already exists, just needs to be called with the right
  args from the authenticated extension client).
- `transcriptLines.append` (or similar) - a batched mutation the service
  worker calls periodically (e.g. every few seconds, not per-line) to flush
  buffered finalized lines to Convex during the call. Don't wait until the
  call ends to upload - if the tab crashes or closes, whatever was flushed
  should survive.
- A way to mark a session's capture as finished when the user clicks "stop."
  Since there's no audio yet in this phase, don't set status to `"ready"`
  (that implies audio is attached, per the Phase 0 schema comment) - use
  `"processing"` or add whatever intermediate status makes sense, and note
  your choice in your final report so Phase 1b (which adds audio and should
  transition the status to `"ready"`) knows what it's picking up.

## In-page UI (minimal, functional, not styled to match the website)

A small floating control the content script injects into the Meet page:
start/stop lesson recording, and a visible indicator that capture is active
(this matters for consent - the person being recorded should be able to see
it's happening, even though the actual consent *agreement* already happened
on the website in Phase 0). This does not need to match the reloop-derived
design system - it's an in-page overlay on someone else's site, not part of
the product's own UI. Keep it simple and legible.

## Testing

No automated test suites, same as Phase 0 - the capture pipeline will keep
changing shape. Verify by joining a real Meet call and checking the Convex
dashboard/data directly, as described in "What done looks like."

## Out of scope for this phase (do not build)

- Any audio capture, `chrome.tabCapture`, offscreen documents, `MediaRecorder`
  - all Phase 1b.
- Transcript review UI on the website (viewing what was captured) - later
  phase. It's fine that the only way to see a session's transcript right now
  is the Convex dashboard.
- Multi-meeting / multi-tab support.
- Production `externally_connectable` origin - dev origin only for now.
