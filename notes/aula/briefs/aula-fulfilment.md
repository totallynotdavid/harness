# aula-fulfilment: physical certificate delivery as a real entity

You own `layers/fulfilment/` and nothing else. It is currently a
`nuxt.config.ts` and a schema file.

## Why this exists

In the system being replaced, a request for a physically printed and posted
certificate was captured through a **Moodle Feedback activity**, and the
secretariat parsed delivery addresses out of survey free text. There was no
state, no queue, and no way to answer "what is outstanding?" without reading
prose.

Here it is a first-class entity with real states. `shared/schema.ts` already
defines `fulfilmentRequest` and is frozen. Read it before you start: it carries
the certificate reference, a method, a status, recipient address, phone and
province.

## Deliverable 1: the request

A student or the secretariat can request physical delivery of an issued
certificate. Validate the address fields with Zod at the boundary. A request
must reference a real, non-revoked certificate.

## Deliverable 2: `/panel/entregas`, the queue

The operator screen, gated on `fulfilment:manage`. This is a working queue, not
a report:

- Filter by status and by province, with the filter state in the URL query
  string so a view is shareable and the back button works.
- Move a request between states from the queue itself, without a full page
  reload and with a visible saved state.
- Every state change is an explicit action. Never infer a state from free text,
  which is the exact failure being replaced.
- Show what an operator preparing a postal run actually needs: recipient, full
  address, province, the certificate's verification code, and how long the
  request has been waiting.

Sort so the oldest waiting request is the most visible thing on the screen.

## Deliverable 3: the student's view of it

A student who requested delivery can see the status of their own request, and
only their own. Scope on `currentUser.personId`, never on an id in the URL. A
signed-in account with a null `personId` sees nothing rather than a guess.

`layers/certificates/server/api/certificates/mine.get.ts` is the reference for
exactly this pattern; read it and follow it. An earlier version of that file
correlated by matching email instead, which was an authorization hole, so do not
invent your own correlation.

## Route rules

`/panel/**` is already `{ isr: false, cache: false }` in the root config, which
is frozen. Authenticated, always fresh, never shared-cached. You do not need to
change it and you must not.

## Note on `/panel`

`layers/secretariat` owns `/panel` itself and its index page. You own
`/panel/entregas` and its subtree, inside your own layer. Nuxt merges page
directories across layers, so do not add or edit anything under
`layers/secretariat`.

## Verification

Beyond the standard checks: run `pnpm db:seed`, which already creates one
`fulfilmentRequest` in the `requested` state, and drive it through every state
transition against a running `pnpm dev`. Report the transitions you exercised.
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
