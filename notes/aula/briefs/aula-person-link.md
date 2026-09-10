# aula-person-link: close the seam between an account and a person

## The gap

`layers/people` owns `person`: anyone a certificate can name, including
external recipients who never log in. `layers/auth` owns `user`: an account
that can sign in. **Nothing connects them.** There is no way to answer "which
person is the signed-in user?"

This was designed and then not built. `layers/people/shared/README.md`, under
"Seam with layers/auth", specifies the answer precisely: `layers/auth`'s `user`
table should carry a **nullable `personId` referencing `people.person.id`**, not
the other way around, so that `people` requires nothing about login and a person
who never logs in stays a first-class case rather than an edge case. The people
layer documented the handoff and the auth layer never picked it up.

Two agents have now hit this, and they diverged, which is why it is being fixed
properly rather than worked around a third time:

- `aula-courses` stopped and reported. `/mis-cursos` was not built, and
  `capturedByPersonId` is left null on every captured grade.
- `aula-record` shipped a stopgap and documented it honestly:
  `layers/certificates/server/api/certificates/mine.get.ts` correlates by
  matching `person.email` to the session email.

**That stopgap is an authorization weakness and closing it is the point of this
task.** `person.email` is nullable and carries no unique constraint. Two person
rows with the same email, or a null email matching nothing, and `.limit(1)`
hands a student a different person's certificate list. It must not survive.

## Deliverable 1: the column

Add a nullable `personId` to `auth.user`, referencing `people.person.id`.

Notes you will need. `layers/auth` lives in its own Postgres schema
(`pgSchema('auth')`), and its README says no other layer's table lives there and
nothing references into it. A foreign key pointing *out* of the auth schema into
`public.person` does not violate that, and it is the direction the people README
specifies. Say so in a comment, because the two documents read as if they
conflict and the next person will wonder.

`user.id` is `text` and `person.id` is `uuid`; the column type follows what it
references, not what sits beside it.

Then generate the migration with drizzle-kit. **You are the only task touching
`drizzle/`**, so the journal is yours and there is no collision risk. Do not
hand-write the SQL, and do not edit either existing migration.

## Deliverable 2: the contract

`CurrentUserView` in `layers/auth/shared/contracts/current-user.ts` is, in its
own words, the auth layer's public surface for identity. Add `personId` to it,
nullable, and populate it wherever the view is built. Every other layer then
reads `currentUser.personId` and never queries `person` to work out who is
signed in.

Update the seed so the development accounts are actually linked; unlinked seed
data would make every consumer look broken.

## Deliverable 3: remove the stopgap and finish what it blocked

- Rewrite `mine.get.ts` to scope on `currentUser.personId`. Delete the email
  correlation and the comment describing it. A signed-in user with no linked
  person gets an empty list, not a guess.
- Build `/mis-cursos` and `/mis-cursos/:code` in `layers/courses`, the two pages
  the blocked task could not write. `/mis-cursos/:code` is the real teaching
  surface: classes in order, each with its materials and, when one exists, the
  Zoom join link, with the next live session the most prominent thing on the
  page. Private, SSR, never shared-cached. **A join URL is visible only to
  someone with an active enrolment in that course** — gate on the enrolment, not
  merely on having a session.
- Populate `capturedByPersonId` when a grade is captured.

## Deliverable 4: finish the alias conversion

`aula-aliases` converted seven layers and scoped an ESLint rule to them,
excluding `catalog`, `courses` and `certificates` because they were under
construction. They have landed. You own all three.

Convert their remaining relative cross-layer imports to `#layers/<name>/...`
(there are 26, and 12 of them are in `layers/certificates`), then widen the
`files` list in `eslint.config.mjs` to cover every layer and delete the comment
explaining the exclusion. Do this **last, as its own commit**, so a mechanical
change never sits in the same commit as a behavioural one.

## Verification

`pnpm test`, `pnpm lint`, `pnpm typecheck`, `pnpm build`. The suite is at 152
tests; it must grow, not shrink.

Then prove the seam works against real data rather than asserting it: run
`pnpm db:seed`, sign in as a seeded student, and confirm `/mis-certificados`
returns that person's certificate and `/mis-cursos` returns their enrolment.
Then confirm the negative case, which is the one that matters: a signed-in
account with `personId` null sees an empty list rather than someone else's.
## Ground rules (identical for every wave-two task)

Read `AGENTS.md` at the repository root first. It states the architecture decisions
you are building inside, not suggestions.

**You own `layers/auth`, `layers/people`, `layers/courses`,
`layers/certificates`, `layers/catalog`, `drizzle/`, `server/` and
`eslint.config.mjs`.** No other task is live, so the seam can be closed in one
piece instead of handed across three briefs again.

Still frozen: `package.json`, `pnpm-lock.yaml`, `nuxt.config.ts`,
`tsconfig.json`, `vitest.config.ts`, `drizzle.config.ts`, and the layers not
listed above.

Three consequences, each of which has bitten this repository before:

- **No new dependencies.** Everything you need is installed: `drizzle-orm`, `zod`,
  `reka-ui`, `qrcode`, `better-auth`, Tailwind v4, Vitest, Playwright. If you
  genuinely need one more, stop and report it instead of editing the manifest.
- **One schema change, and only the one named above.** `personId` on
  `auth.user`, plus its generated migration. Nothing else in any
  `shared/schema.ts` moves.
- **Seed changes only to link accounts to people.** The existing data (a graded
  student, an ungraded student, a pre-issued row, a deliberately stale row) is
  deliberate and must survive.

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
