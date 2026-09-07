# Brief: Verbatim - Phase 1b (audio capture)

## Context

Phase 1a (landed on `master`) built the browser extension's caption capture:
a WXT-based MV3 extension that watches Google Meet's live captions, uploads
finalized transcript lines to Convex in batches, and authenticates via a
website-to-extension token handoff (`/extension/connect`). Verified against
a real Convex deployment with a minted auth token and a simulated Meet DOM -
there is no browser on this build machine, so that's as real as automated
verification got. A human still needs to do the actual browser click-through
(`SETUP.md` §7).

This phase adds the other half of capture: recording the call's audio
alongside the transcript, so the tutor can later hear exactly what was said
instead of trusting Meet's sometimes-wrong live transcription. **Scope ends
at capture and upload.** Playback UI - clicking a transcript line to hear
that moment - is a later phase (Phase 2, review UI) and needs none of your
attention here. Don't build any playback, per-line clip slicing, or waveform
UI in this phase.

## What "done" looks like

When a lesson session stops, Convex has one continuous audio file attached
to that `lessonSessions` record (`audioStorageId`, `audioDurationMs`), the
session's `status` is `"ready"` (not `"processing"` - that transition is
this phase's job), and the recording's own timeline is calibrated against
the same `startMs`/`endMs` clock the transcript lines already use (Phase 1a:
relative to capture start, not epoch - documented in
`apps/extension/src/background/service.ts` and the Convex `lessonSessions`/
`transcriptLines` code). A later phase seeking this audio file to a
transcript line's `startMs` needs to land on the right moment; get that
alignment right now, it's much harder to retrofit.

As with Phase 1a, verify everything you can without a browser (there still
isn't one on this machine), and clearly hand off what's left for a real
click-through test.

## The real technical questions - research these, don't guess

Two things here are genuinely uncertain and deserve real research (Context7
for current Chrome extension docs, `gh` for real-world reference
implementations) before you commit to an approach:

1. **Where does the tutor's own microphone get captured from?**
   `chrome.tabCapture.getMediaStreamId()` (called from the service worker,
   requires the user-gesture that "Start lesson" already provides) gives you
   the Meet tab's own audio output - normally the remote participant(s).
   Whether an MV3 **offscreen document** can *also* successfully call
   `navigator.mediaDevices.getUserMedia({audio: true})` for the local mic,
   and what permission-prompt behavior that has (offscreen documents have
   their own `chrome-extension://` origin, not the Meet page's origin) is
   the open question. Verify this against current docs and real examples,
   don't assume it works the way a normal page's mic permission would.
   Google's own recording sample
   (`developer.chrome.com/docs/extensions/how-to/web-platform/screen-capture`)
   and real extensions doing exactly this - `wxt-dev/examples`'s offscreen
   examples, and Meet-recording extensions found in prior research in this
   repo (`vivek-nexus/transcriptonic`,
   `recallai/chrome-recording-transcription-extension`) - are worth reading
   the actual source of, not just the docs.
2. **How do you keep the user able to hear the meeting once `tabCapture`
   grabs the tab's audio?** `tabCapture` mutes the tab's normal audio
   output. You need to route the captured tab-audio stream back out to the
   user's speakers (e.g. connect it to the offscreen document's
   `AudioContext.destination` in addition to the recording destination), or
   the tutor loses their own audio the moment recording starts. Verify this
   is handled and confirm you haven't just made the extension silence the
   call for its user.

## Recording flow (offscreen document, following WXT's convention)

- Use WXT's documented offscreen-entrypoint pattern (`wxt-dev/examples`:
  `offscreen-document-setup`) rather than hand-rolling `chrome.offscreen`
  wiring - pull the actual example via `gh` and follow its structure. Add
  the `offscreen` and `tabCapture` permissions.
- On "Start lesson" (after `startSession` succeeds - **audio capture must
  never start on its own; it's gated on the same consent-checked
  `startSession` call Phase 1a already makes, not a separate path**): the
  service worker gets a tab-capture stream ID for the active Meet tab,
  ensures the offscreen document exists, and hands it the stream ID.
- The offscreen document acquires the tab-audio stream from that ID, and
  (per your research above) the tutor's own mic. Mix both through
  `AudioContext.createMediaStreamDestination()`. Record the mixed stream
  with `MediaRecorder` (WebM/Opus).
- Buffer recorded chunks in the offscreen document for the session's
  duration - a lesson-length Opus recording is tens of MB, well within
  reasonable in-memory bounds for the length of one call. Don't build
  incremental/streaming upload in this phase; assembling and uploading once
  on "Stop" is enough and much simpler. (If you find a concrete reason this
  is unsafe - e.g. real memory pressure in your own testing - say so in your
  report rather than silently building the more complex streaming version.)
- On "Stop": assemble the recorded chunks into one Blob, get an upload URL
  via Convex's `ctx.storage.generateUploadUrl()` (already confirmed in this
  project's research to accept arbitrarily large files - not the 20MB-capped
  HTTP-action path), POST the blob, then call a Convex mutation with the
  resulting storage ID and duration to attach it to the `lessonSessions`
  record and move `status` from `"processing"` to `"ready"`.

## Clock calibration

Phase 1a's transcript lines use `startMs`/`endMs` relative to capture start.
Pin the offscreen recording's own t=0 to that same reference point as
precisely as you can - a short handshake between the service worker (which
knows when it told the content script/offscreen document to start) and the
actual moment `MediaRecorder.start()` fires is reasonable. Document whatever
offset or drift you measure; a later phase applying padding around a
transcript line's timestamps when seeking the audio file needs to know how
much slack to add.

## Testing

Same policy and same constraint as Phase 1a: no automated test suites (the
pipeline will keep changing shape), and no browser/display on this machine.
Verify what you can - the upload-and-finalize path against the real
deployment (same technique as Phase 1a: a stubbed `chrome`/offscreen harness
driving the actual built code with a real Blob and a real minted auth
token), typecheck, and build. Clearly say what still needs a human with a
browser and a real Meet call, and update `SETUP.md` §7 if the manual
verification steps changed.

## Out of scope for this phase (do not build)

- Any playback UI, per-sentence clip slicing, or waveform display - Phase 2.
- Speaker-isolated/separate audio tracks - Phase 0's spec already decided on
  one mixed recording for the simplest 1:1 lesson experience.
- Streaming/incremental upload during the call - buffer and upload once on
  stop, per above, unless your own testing finds a concrete reason not to.
- Multi-meeting/multi-tab support.
