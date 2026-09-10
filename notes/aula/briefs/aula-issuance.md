# aula-issuance: pre-issue as a working screen

You own `layers/issuance/` and nothing else. It is currently a
`nuxt.config.ts`, a `shared/schema.ts`, a `shared/fingerprint.ts` and a
README. Read all four before you write anything: they are the contract, and
they are frozen.

## Why this exists

This is the reason the whole platform is being rebuilt. CICAT signs and prints
certificates before the exam happens. When a student passes, the sheet already
in the drawer has to verify online with the code printed on it. The old system
could not do this, so it faked a certificate row inside a transaction, read it
to render a PDF, and deleted it before commit.

`issuance` is that shadow record made real. Nothing here may resort to a
transient row.

## What is already decided

`shared/README.md` states four decisions. You are implementing them, not
revisiting them. The two that shape most of your work:

**Staleness is read, not stored.** There is no `stale` status. A row is stale
when `renderedFingerprint` differs from `currentFingerprint`. `isStale()` in
`fingerprint.ts` is that comparison. Never add a status, a boolean, or a
timestamp that duplicates it.

**The verification code is generated once.** It is carried to
`certificate.verificationCode` verbatim on release. Never regenerate it.

## Deliverable 1: the state machine

`shared/transitions.ts`, a pure module with no IO, tested directly.
`layers/fulfilment/shared/transitions.ts` is the shape to follow: an explicit
map of which statuses may follow which, and a function that either returns the
next state or explains the refusal.

The four statuses are `pending`, `rendered`, `released` and `revoked`.
Released and revoked are terminal. Release requires a passing grade and a
non-stale rendered PDF; work out what "passing" means from
`layers/courses` rather than inventing a threshold.

## Deliverable 2: the routes

Under `server/api/`, each validating with Zod and each calling
`requirePreissueAccess(event, courseId)` from
`#layers/auth/server/utils/require-preissue-access`. That resolver already
exists and already distinguishes `certificate:preissue:all` from
`:own`. Do not write your own scope check and do not test `role === 'admin'`.

- Create the shadow rows for a course cohort. Idempotent: the unique index on
  `(courseId, personId, cargoId)` is the guard, so re-running must not error.
- Render, which fills `renderedFingerprint` and `renderedAt`. Reuse
  `layers/certificates/server/render`; do not build a second renderer.
- Release, which creates the `certificate` row, carries the code across, and
  sets `certificateId` and `releasedAt`.
- Revoke.

Recompute `currentFingerprint` wherever an input changes and record
`lastDirtyReason`. That reason is observability only; never branch on it.

## Deliverable 3: the operator screen

`app/pages/panel/emision/[code].vue`, one course per page, gated on the same
resolver. That route path is assigned to you: `/panel` belongs to
`layers/secretariat` and `/panel/entregas` to `layers/fulfilment`, so stay
under `/panel/emision`. This is
the screen someone uses the morning of a printing run, so it answers, at a
glance and without a click:

- Who has a shadow row and who does not.
- Which rows are stale, and why, using `lastDirtyReason`.
- Which are ready to release because the student passed.

Bulk actions matter here: preparing forty certificates one row at a time is
the failure being replaced. Filter state belongs in the URL query string.

`pnpm db:seed` gives you two issuance rows, one deliberately stale (Carla's
profile changed after her PDF was rendered). Build against that, and make the
stale one obviously stale on screen.

## Out of scope

The certificate record, its PDF route, and its public verification page are
`layers/certificates` and `layers/verification`, both landed and frozen. You
consume them. If you need something they do not expose, report it.
