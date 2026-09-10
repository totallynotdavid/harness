# aula-verification: the public verification page

You own `layers/verification/` and nothing else. It is currently one
`nuxt.config.ts` and no code.

## Why this is the most important screen in the product

`/verificar/:code` is what a stranger sees when they scan the QR printed on a
paper certificate. It is the highest-traffic public surface and the only one
most people will ever load. The design notes are blunt about it: **it should
look like a document, not a dashboard.**

## What already exists

`layers/certificates` has landed and is frozen for you. It gives you:

- `GET /api/certificates/:code` — reads one certificate by verification code and
  returns its frozen `payload`.
- `GET /api/certificates/:code/pdf` — the stored PDF.
- The `certificate` table carries `revokedAt` and `revokedReason`, and the
  rendering pipeline renders the certificate as HTML before it becomes a PDF.

Read `layers/certificates/shared/payload.ts` for the exact shape of a payload.
It is frozen at issuance and contains the resolved name, gendered title,
gendered cargo label, course name and dates.

## Deliverable: `/verificar/:code`

Three states, all of which must be designed, not just handled:

1. **Valid.** Show the certificate itself. The rendering pipeline already
   produces HTML, so show the real artifact rather than a table describing it,
   then the verification facts around it: holder, course, role, dates, issuing
   authority, issue date, and an unambiguous authentic verdict.
2. **Revoked.** Resolves, and resolves *as revoked*. This is not an error state
   and must not be styled as a 404. Show the certificate, the revocation, and
   its date. Someone holding a revoked printed certificate must be told clearly
   that it is no longer valid.
3. **Not found.** A plain, calm page. No stack trace, no dashboard chrome. Do
   not leak whether a code was never issued or was deleted.

## The constraints that are the whole point

The root `nuxt.config.ts` already sets a one-year `s-maxage` with
stale-while-revalidate on `/verificar/**`, because an issued certificate never
changes. That configuration is frozen and you must not change it, but you must
build so that it is correct:

- **It must work with JavaScript disabled.** It is a document. Test this: load
  the page with JS off and confirm it renders completely. If the main content
  needs a client-side fetch, it is wrong.
- **Under 50 KB of JavaScript**, and under 100 ms to first byte from cache.
  Measure both and report the numbers you actually got.
- **No authentication, and no session-dependent rendering of any kind.** A page
  that varies by viewer cannot be shared-cached for a year. Do not read the
  session, do not render a header that shows a signed-in name, do not import
  anything that does.
- **Leak nothing beyond the certificate.** No person id, no course id, no
  internal identifiers, no enrolment or grade data. The frozen payload plus the
  revocation status is the entire surface.

Legible on a phone, because that is where a scanned QR lands.

## After it works

`.github/lighthouse/lighthouserc.cjs` currently has
`resource-summary:script:size` set to `warn` with a note saying to flip it back
to `error` at 51200 scoped to this page once it ships. That file is not yours,
so do not edit it. Report the measured script size in your final message so the
captain can make that change.
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
