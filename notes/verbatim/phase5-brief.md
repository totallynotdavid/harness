# Brief: Verbatim - Phase 5 (automated pronunciation scoring)

## Context

Phases 0-4 (all landed on `master`) built capture, review, the study loop,
and interview coaching - all synchronous Convex work plus browser capture.
This phase is different in kind: it calls **external, cost-bearing ML
services** from Convex, on a job that can take minutes, and produces
suggestions a tutor reviews rather than ground truth. Read this brief
fully before writing code - the shape of this phase (async job
orchestration, a new non-user auth surface, real external cost) has no
precedent yet in this codebase.

Real research (Context7 against Convex's docs, `gh` against the actual
repos, current pricing pages) already happened for this phase and the
findings below are current as of 2026-09-04. Verify anything you're about
to commit real money or infrastructure to before building against it -
pricing and APIs move - but you do not need to re-derive these from
scratch.

## Two external workers, two different shapes

**1. WhisperX, for auto-flagging low-confidence words.** Use Replicate's
public, version-pinned WhisperX model
(`replicate.com/victor-upmeet/whisperx`) rather than hosting anything
yourself - it already returns word-level timestamps and confidence, and
Replicate supports async completion via webhook (no polling, no GPU
infrastructure to run). At realistic volume (a handful of lesson-length
files a week) this is roughly $0.17-0.34 per lesson. Pin the model
version explicitly.

**2. OpenPronounce (`Halleck45/OpenPronounce`), for phoneme-level
mispronunciation scoring.** CPU-only (no GPU needed), actively maintained,
ships a FastAPI server (`server.py`) and a Dockerfile you can deploy
as-is. **Critical constraint: it loads the whole waveform and performs
unchunked inference - never feed it a full lesson file.** Run it per
segment (a single transcript line or a short flagged span), which is a
natural fit since the data model is already line-granular. There is no
ready-made hosted deployment for it anywhere (unlike WhisperX) - you have
to deploy the existing container yourself, to whatever scale-to-zero
platform you judge simplest to operate (Modal and Fly.io Machines both
support pay-per-use CPU containers with autostop; your call, but avoid an
always-on box billed by the month for a workload this infrequent). Only
run one worker per instance - the server does blocking inference inside
async endpoints, it is not internally concurrent.

Decide, and say in your report: what "expected text" you feed
`compare_audio_with_text()` for a given segment. The transcript line's own
ASR text is the only text you have without new tutor input - that's likely
the right default (it's the ASR's best guess at what was said, which is
what a phoneme comparison needs), but note the tension explicitly rather
than picking it silently: if the ASR itself mis-transcribed a
mispronounced word, comparing against its own guess could mask exactly the
error you're trying to catch. If you see a cheap way to mitigate this,
say so; if not, document it as a known limitation for a future pass.

## Architecture: enqueue-and-callback, not a synchronous action

Convex's own documented pattern for exactly this job shape (external work,
minutes-long, needs to outlive the calling connection) is: a mutation
records intent and schedules an internal action; the action kicks off the
external job and returns; the worker calls back into Convex when done. Do
not write one long-running action that awaits the whole pipeline
synchronously - Convex Node-runtime actions cap at 10 minutes, and this
job's duration varies with provider/queue state. Follow the shape Convex's
own RunPod walkthrough documents (real example: `stack.convex.dev/convex-
gpu-runpod-workflows`), not a polling loop.

**New auth surface:** the external worker calling back into Convex is not
a signed-in user - it cannot carry a Convex Auth JWT. Give the callback
its own HTTP action, validated by a shared secret (an env var, checked
before anything else runs), which then invokes an internal mutation. This
is a genuinely new pattern in this codebase (every other Convex Auth check
so far has been about which paired user is calling) - don't try to route
it through the existing user-auth helpers in `model/sessions.ts`.

Store large word/phoneme-level result payloads as files via Convex
storage rather than one oversized database document, if a full lesson's
worth of results is large enough to matter - your judgment on the
threshold.

## Draft annotations, never auto-published

Per the spec: model output becomes something the tutor confirms or
dismisses, not a fact merged straight into `annotations`. Design a real
draft/suggestion state - a `source: "tutor" | "auto"` field plus a
pending/confirmed/dismissed status on `annotations` itself, or a separate
suggestions table that promotes into `annotations` on confirm. Either is
fine; don't let auto-generated output look indistinguishable from
something the tutor actually wrote once confirmed, and don't let it appear
in the study queue or trends view before a tutor has acted on it.

## When does this run?

Real money is spent per run. Auto-running this on every single lesson the
moment it's `ready` is one option; a tutor-triggered "Analyze this lesson"
action from the review page is another, giving the tutor cost control.
Pick one (or make it configurable) and justify the choice in your report -
don't default to automatic-on-every-lesson without considering the cost
tradeoff explicitly.

## Setup dependencies - new human steps

You cannot provision these yourself. A Replicate API token, hosting
credentials for wherever you deploy OpenPronounce, and the callback shared
secret are all new manual steps - add them to `SETUP.md` clearly, the same
way Convex/Google OAuth setup was documented in Phase 0. Say plainly in
your report that this phase cannot be verified end-to-end (real worker
calls, real callback) without David providing those credentials, and be
precise about exactly what he needs to go create/obtain.

## Testing - cost-aware, not just browser-aware

Same no-automated-test-suite policy as every phase, but this phase adds a
new constraint the earlier ones didn't have: **verification calls to
Replicate/OpenPronounce cost real money once credentials exist.** Verify
the plumbing (the mutation/action/callback/mutation chain, the auth
check on the callback endpoint, the draft-annotation state machine) with a
stubbed worker hitting the real callback HTTP action - that costs nothing
and is where most real bugs will be. If credentials are available and you
choose to make real calls, use the shortest, cheapest test clip you can
(seconds, not a real lesson-length file) and say exactly what you spent
and on what, don't run repeated real-money verification passes. If no
credentials are available in this environment (likely, given they're new
human-provisioned secrets), say so plainly rather than guessing at
behavior you couldn't observe.

## Out of scope for this phase (do not build)

- Any UI for editing the model's own confidence/score numbers - tutor
  reviews text, confirms or dismisses, that's the whole interaction.
- Multi-language scoring (OpenPronounce supports several languages, but
  this product is English-only per the spec - don't build language
  selection).
- Real-time/live scoring during a lesson - this runs on a completed,
  `ready` lesson only.
