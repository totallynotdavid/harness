# Brief: Verbatim - Phase 0 (Foundation)

## Product, in one paragraph

Verbatim is a production system (not an MVP - it will be built across several
more passes after this one) that helps an English tutor and a Spanish-speaking
student preparing for software-engineering job interviews review their Google
Meet lessons: full transcript (not Meet's two-line caption window), click any
sentence to hear exactly how it was said, annotate mispronunciations, and build
a study queue from real lesson evidence. A browser extension (built in a later
phase) captures captions and audio from Meet; this website is the whole product
surface - review, annotation, study, everything.

This phase builds the foundation only: monorepo, auth, empty dashboard shell,
Convex schema, and the consent data model. No transcript, audio, or review
features yet - those are later phases. Do not build ahead of this phase's
scope; the next passes depend on this one being a clean, complete slice, not a
head start on phase 2.

## Architecture (decided, do not re-litigate)

- **Website**: Next.js (App Router) + React + TypeScript.
- **Styling**: Tailwind CSS 4, CSS-first config (no `tailwind.config.js/ts` -
  configure via `@theme` in CSS per Tailwind 4's approach). Use Context7 to
  confirm current Tailwind 4 CSS-first config syntax before writing it - don't
  guess from v3-era memory.
- **Component library**: build a local `packages/ui` using Radix primitives +
  `tailwind-variants` + `class-variance-authority` + `tailwind-merge`. This
  mirrors the stack of an existing product (reloop-labs/reloop,
  `apps/frontend/web`) whose visual language this product should match. Use
  `gh api repos/reloop-labs/reloop/contents/<path>` or `gh repo clone
  reloop-labs/reloop /tmp/reloop-reference -- --depth 1` to pull actual
  reference files - don't approximate from description alone. Specifically
  worth pulling for direct adaptation:
  - `packages/tailwind/style.css` - color/typography/spacing/dark-mode design
    tokens. Port these values, don't invent new ones.
  - `apps/frontend/web/src/app/(home)/components/hero-dashboard-sidebar.tsx` -
    navigation shell (sidebar, active-state treatment, theme switcher) for
    this phase's dashboard.
  - `packages/ui/src/components/tab-menu-horizontal.tsx`, `status-badge.tsx`,
    `badge.tsx` - reusable primitives, useful now for a nav/status treatment
    and later for Transcript/Audio/Notes tabs.
  Framer Motion for transitions, `next-themes` for dark mode (reloop uses
  both).
- **Monorepo**: Bun workspaces + Turborepo.
- **Backend**: Convex - database, file storage, serverless functions,
  scheduled jobs, and auth, all on one platform. Use Context7
  (`resolve-library-id` -> `query-docs`) for current Convex and Convex Auth
  API shape before writing schema/functions - the APIs move and training data
  may be stale.
- **Auth**: Convex Auth (`@convex-dev/auth`) with Google as the *only*
  provider (`@auth/core/providers/google`). No password auth, no other OAuth
  providers - every user already has a Google account since they use Google
  Meet for lessons. Confirm current setup steps via Context7
  (`/get-convex/convex-auth` or `/websites/labs_convex_dev_auth`).

## Repo layout to produce

```
apps/
  web/          # Next.js website
packages/
  ui/           # shared component library (reloop-styled)
  convex/       # Convex schema + functions, imported by apps/web
```

Do not create `apps/extension` in this phase - that's Phase 1's job. An empty
placeholder package left half-configured is worse than not having it yet.

## Convex schema to define (full shape, even though most fields go unused until later phases)

Define the whole schema now so later phases extend it instead of
retrofitting it:

- `users` - googleSub, name, email, role (`"tutor" | "student"`), a
  `pairedWithUserId` field linking the one tutor<->student pair (this product
  assumes a single active pairing at launch - do not build multi-student
  support, that's explicitly deferred).
- `lessonSessions` - tutorId, studentId, startedAt, endedAt, status
  (`"recording" | "processing" | "ready" | "incomplete"`), audioStorageId
  (optional, `Id<"_storage">`), audioDurationMs (optional), consentTutor
  (boolean), consentStudent (boolean).
- `transcriptLines` - sessionId, speakerId, text, startMs, endMs, order.
- `annotations` - sessionId, transcriptLineId, type (`"pronunciation" |
  "grammar" | "word-choice" | "filler" | "interview-structure" |
  "technical"`), note, authorId, createdAt.
- `reviewCards` - sessionId, sourceAnnotationId, dueAt, interval, ease.

No functions need to read/write `transcriptLines`, `annotations`, or
`reviewCards` yet in this phase - just define the schema shape. `users` and
`lessonSessions` need real mutations/queries because this phase's UI touches
them (see below).

## What this phase's website must actually do

1. **Sign in with Google** via Convex Auth. After sign-in, a user with no
   `role` set yet should land on a simple "are you the tutor or the student"
   selection screen that sets their role once (this is a one-time setup step,
   not a settings toggle to rebuild later - keep it simple).
2. **Pairing**: since this is a single tutor/student pair, the simplest
   correct approach is an invite-link or invite-code flow - the first user to
   sign in and pick a role can generate a code; the second user enters it
   during their own first sign-in to link the pairing. Keep this minimal; it
   does not need to support multiple pending invites or revocation in this
   phase.
3. **Empty dashboard shell**: authenticated, paired users land on a dashboard
   using reloop's sidebar/header/theme-toggle layout language, with an empty
   "no lessons yet" state (there's nothing to show yet - transcript/audio
   features are later phases). This proves the shell, auth, and design tokens
   work end to end.
4. **Consent as a first-class data model, not a UI afterthought**: a lesson
   session cannot be marked recordable unless both `consentTutor` and
   `consentStudent` are true. Since there's no recording flow yet in this
   phase, this means: build the `lessonSessions` mutations to require both
   consent booleans before a session can transition out of a not-yet-defined
   "pending consent" concept, and add a settings-page toggle per user where
   each person can record their standing consent to being recorded during
   lessons (revocable). Don't build the actual recording trigger - that's
   Phase 1 - but the consent data and its enforcement in mutations must exist
   now, since it's a requirement the whole system is built around, not a
   detail to bolt on later.

## Things you cannot fully finish, and how to handle them

- **Convex project provisioning** (`npx convex dev` / `npx convex login`)
  requires an interactive browser OAuth login. You cannot complete this
  yourself. Write all the schema/functions/client code as if a Convex
  deployment exists, get it to typecheck, and write a `SETUP.md` at the repo
  root with the exact commands David needs to run once (`bunx convex dev`,
  etc.) to provision the deployment and generate `convex/_generated`.
- **Google OAuth client credentials** (client ID/secret, authorized redirect
  URI) must be created in Google Cloud Console by David - you cannot create
  these. Document the exact steps and the redirect URI format Convex Auth
  expects in `SETUP.md`, and reference env vars by name
  (`AUTH_GOOGLE_ID`/`AUTH_GOOGLE_SECRET` or whatever the current Convex Auth
  docs specify - confirm via Context7) rather than inventing values.
- If you cannot run a live dev server end-to-end because of the above,
  that's expected for this phase - get everything to the point where the only
  remaining step is those two one-time human actions, and say so clearly in
  your final report.

## Testing

Do not add automated test suites. The schema and UI will keep changing shape
across the next several phases; tests written now are pure maintenance cost.
Verify by getting the app to build/typecheck cleanly and, if you can reach a
working dev server, manually clicking through sign-in -> role selection ->
pairing -> empty dashboard.

## Out of scope for this phase (do not build)

- The browser extension (any of it).
- Transcript display, audio playback, annotations UI, spaced repetition,
  trends, interview question bank - all later phases.
- Multi-student/multi-tutor support.
- Any sign-in method besides Google.
