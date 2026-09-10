# aula-courses: teaching, the public catalogue, and grade capture

You own `layers/courses/` and nothing else.

## Why this task exists

The captain answered the one blocking question directly: **teaching is not
vestigial.** The Moodle courses being replaced carry real material and real Zoom
links, and each class has both. So this application owns courses, not just the
certificates that come out of them. Grade capture is day-one scope, because a
certificate is gated on a grade and prints that grade in words.

## What already exists

`layers/courses/shared/schema.ts` is frozen and complete: `course`,
`courseClass` (a session within a course, ordered by `sequence`), `material`
(document, video, link), `liveSession` (Zoom join URL plus start and end),
`enrolment`, and `grade`.

Read the comment on `grade`. It is the single most important decision in your
layer: **there is no "not graded yet" sentinel.** Absence of a row means the
exam has not happened. The system being replaced overloaded a stored `0` to mean
both "ungraded" and "failed with zero", and needed a patched Moodle grade
element to render blank instead of "0 (cero)". Do not reintroduce that
ambiguity anywhere: not in a query, not in a default, not in a UI placeholder. A
real 0 is a real row, and ungraded is no row.

`layers/courses/shared/grade-to-words.ts` already converts a 0-20 score to
Spanish words and has tests. It is yours, in your layer. Use it; extend it only
if a case is genuinely missing.

## Deliverable 1: the public catalogue

- `/cursos` — every course, with dates and a short description. Public, no auth.
- `/cursos/:code` — one course: description, dates, and its classes in sequence
  order with titles and schedule. Public, no auth.

These carry `isr: 300` from the root route rules, which is already configured.
That means **they must render correctly with no session and no JavaScript.**
Test that: load them logged out, and load them with JavaScript disabled. If a
public page needs a client-side fetch to show its main content, it is wrong.

Do not leak anything private through these routes. A public course page shows
the course and its class titles. It does not show enrolments, grades, names, or
Zoom join URLs.

## Deliverable 2: the enrolled student's course view

- `/mis-cursos` — the courses this person is enrolled in.
- `/mis-cursos/:code` — the real teaching surface: classes in order, each with
  its materials and, when one exists, the Zoom join link.

Private and per-user: SSR, never shared-cached. A join URL is only ever visible
to someone with an active enrolment in that course. Gate the server routes on
the enrolment, not only on the session.

Design this as the screen a student actually opens ten minutes before class.
The next live session should be the most prominent thing on it.

## Deliverable 3: grade capture

The teacher and secretariat surface for entering grades against enrolments:
`/cursos/:code/notas`, gated on `certificate:preissue:own` for a teacher and
`certificate:preissue:all` for secretariat and admin.

Requirements:

- Entering a grade inserts a row; clearing a grade deletes the row. Never write
  a sentinel.
- Scores are integers 0-20. The database has a check constraint; validate with
  Zod at the boundary too, so the user gets a real message rather than a 500.
- Show the words alongside the number as the operator types, using
  `grade-to-words.ts`, because that is exactly what will be printed.
- Bulk entry for a whole course roster must be practical: a keyboard-navigable
  column, saved without a full page reload, with a visible saved state.
- Record `capturedByPersonId`.

## Do not build

No quiz engine, no assessment authoring, no attendance. Grades are captured, not
computed. That boundary is deliberate and it is not yours to move.
## Ground rules (identical for every wave-two task)

Read `AGENTS.md` at the repository root first. It states the architecture decisions
you are building inside, not suggestions.

**You own exactly one layer directory. Everything else is frozen.**

Frozen, and you must not edit any of it: the repository root (`package.json`,
`pnpm-lock.yaml`, `nuxt.config.ts`, `vitest.config.ts`, `tsconfig.json`,
`eslint.config.mjs`, `knip.ts`, `drizzle.config.ts`), `drizzle/`, `server/`,
`app/`, `shared/`, and every `layers/*` directory other than your own.

Three consequences, each of which has bitten this repository before:

- **No new dependencies.** Everything you need is installed: `drizzle-orm`, `zod`,
  `reka-ui`, `qrcode`, `better-auth`, Tailwind v4, Vitest, Playwright. If you
  genuinely need one more, stop and report it instead of editing the manifest.
- **No schema changes.** Do not edit any `shared/schema.ts`, do not run
  `drizzle-kit generate`, do not add a migration. The schema and the two
  migrations on master are the contract. If a column you need is missing, stop
  and report it, then build against what exists.
- **No seed changes.** `server/database/seed.ts` already seeds realistic Spanish
  data across every table, including a graded student, an ungraded student, a
  pre-issued row and a deliberately stale row. Run `pnpm db:seed` and build
  against it.

**Design system.** `layers/base/app/components/` has Button, Input, Checkbox,
Textarea, Badge, Skeleton, EmptyState, Pagination, Toaster, and reka-ui-backed
dialog, popover, select, table, tabs, tooltip, dropdown-menu, breadcrumb,
command-palette. Import them. Do not reinvent them, and do not edit them. If a
primitive is missing, compose one inside your own layer from the tokens in
`app/assets/css/main.css`; do not reach into `layers/base` to add it.

**Data flow is direct.** Nitro route handler validates with Zod, queries with
Drizzle, returns a typed object. No repository layer, no service layer, no DTO
mapping. The two exceptions in `AGENTS.md` (auth domain rules, the issuance
state machine) are not yours.

**Auth.** Every server route that touches privileged data calls
`requirePermission(event, '<permission>')` from
`layers/auth/server/utils/require-permission`. The permission strings are the
union in `layers/auth/shared/domain/rbac.ts`. Never check `role === 'admin'`
inline.

**Verify before you report done.** `pnpm test`, `pnpm lint`, `pnpm typecheck`,
`pnpm build`, plus one direct check against `pnpm dev` with real seeded data
(curl the routes you wrote, load the pages you wrote). A passing unit test on a
pure function is not evidence that a page renders. If something fails, say so
with the output; do not report success on a partial run.

**Do not commit and do not push.** Leave your work uncommitted in the worktree.
