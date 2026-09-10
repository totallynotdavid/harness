# aula-scope: make `:own` mean something

## The defect

`layers/auth/shared/domain/rbac.ts` declares two pre-issue permissions:

    'certificate:preissue:own'   // "a teacher, for their own courses"
    'certificate:preissue:all'   // "secretariat and admin, across every course"

**Nothing enforces the `:own` scope.** Two routes reached it independently and
both collapsed it into `:all`:

- `layers/courses/server/utils/require-grade-capture-access.ts` grants access if
  the role holds *either* permission, then never checks the course.
- `layers/certificates/server/utils/can-create-certificate.ts` does the same for
  `POST /api/certificates`.

So a teacher can capture grades for any course in the system and issue
certificates for any course in the system. Both files are careful, tested, and
honestly commented. Neither is wrong on its own terms. That is what makes this
worth fixing properly rather than patching twice.

**The root cause is that `:own` is currently unenforceable.** Search the schema:
no `course` column, no join table, nothing anywhere records which courses a
teacher teaches. The permission vocabulary promises a scope the data model
cannot express, so the only implementation available was to ignore it.

This is the same shape as the bug this whole project exists to replace. In the
Moodle system being retired, deleting an issued certificate was guarded by the
*read* capability. Here, "pre-issue for your own course" is guarded by
"pre-issue for any course." A permission that does not mean what it says is
worse than one that was never declared, because it reads as a control during
review.

## Deliverable 1: make teaching assignment a fact in the database

Add the missing relationship to `layers/courses`: which people teach which
courses. A course has more than one teacher in practice, and a teacher teaches
more than one course, so this is a join table, not a column.

Model it on the existing `enrolment` table, which is the same shape for the
student side: person plus course plus a status, with a unique index on the pair.
Follow the conventions already in that file (uuid primary keys, timestamptz
`createdAt`/`updatedAt`, a unique index on the natural key).

Generate the migration with drizzle-kit. You are the only task touching
`drizzle/`, so the journal is yours. Do not hand-write SQL and do not edit the
three existing migrations.

Seed it: the seeded course needs a teacher, and there must be a second teacher
who does **not** teach it, or the negative case cannot be tested.

## Deliverable 2: one scope resolver, not two call sites

Replace both helpers with a single shared function that answers the real
question: *may this user act on this course?* It must:

- Return true for a role holding `certificate:preissue:all`, with no course
  lookup, because that permission means exactly "any course".
- For a role holding only `certificate:preissue:own`, return true **only** when
  that user's `personId` teaches the course in question. A user with a null
  `personId` never passes the `:own` branch.
- Return false otherwise, and keep the existing 401-vs-403 distinction: not
  signed in is 401, signed in without the right is 403.

Put it where both consumers can reach it without a layer reaching sideways into
another layer's server utils. It is an auth-domain rule, and `AGENTS.md` names
auth domain rules as one of the two explicit exceptions to "data flow is
direct", so `layers/auth` is the right home.

Then convert every call site. `require-grade-capture-access.ts` and
`can-create-certificate.ts` both disappear into it.

## Deliverable 3: prove the scope with tests, including the negative

The tests that matter are the ones that would have caught this:

- a teacher who teaches the course: allowed
- a teacher who does **not** teach the course: denied with 403
- secretariat and admin on a course they have no relationship to: allowed
- a signed-in user with `personId` null holding only `:own`: denied
- not signed in: 401

Write them against the seeded data, and make at least one an end-to-end check
through the real route rather than only against the pure function, because the
pure function was never the part that was broken.

## Deliverable 4: audit the rest of the vocabulary

`:own` also appears on `certificate:read:own` and `people:read:own`. Check each
consumer and report, in your final message, whether each one enforces its scope
or silently widens it like these two did. Fix any that are actually wrong.
`certificate:read:own` in `mine.get.ts` is already correct: it scopes on
`currentUser.personId` and returns an empty list when that is null. Use it as
the reference for what "correct" looks like.

Do not widen this into a general RBAC redesign. The vocabulary is right; it is
the enforcement that is missing.

## Verification

`pnpm test` (currently 162 passing, it must grow), `pnpm lint`, `pnpm typecheck`,
`pnpm build`. Then `pnpm db:seed` and exercise the deny path against a running
`pnpm dev`: sign in as the teacher who does not teach the seeded course and
confirm a 403 from both the grade-capture route and the certificate-create
route. Report the actual responses you saw.
## Ground rules (identical for every wave-two task)

Read `AGENTS.md` at the repository root first. It states the architecture decisions
you are building inside, not suggestions.

**You own `layers/auth`, `layers/courses`, `layers/certificates`, `drizzle/`
and `server/`.** Other agents are building in `layers/verification` and
`layers/fulfilment` at the same time; do not touch those, or any other layer.

Frozen: `package.json`, `pnpm-lock.yaml`, `nuxt.config.ts`, `tsconfig.json`,
`vitest.config.ts`, `eslint.config.mjs`, `drizzle.config.ts`.

Three consequences, each of which has bitten this repository before:

- **No new dependencies.** Everything you need is installed: `drizzle-orm`, `zod`,
  `reka-ui`, `qrcode`, `better-auth`, Tailwind v4, Vitest, Playwright. If you
  genuinely need one more, stop and report it instead of editing the manifest.
- **One schema addition, the teaching-assignment table named above, plus its
  generated migration.** Nothing else in any `shared/schema.ts` moves.
- **Seed changes only to add teaching assignments and a second teacher.** The
  existing data is deliberate and must survive.

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
