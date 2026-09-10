# aula-record: the issued certificate, its storage, and the student's list

You own `layers/certificates/` and nothing else.

## What already exists in your layer

The rendering pipeline landed and is yours to build on, not to rewrite:
`server/render/` has `browser-pool.ts` (one pooled warm headless browser, never
spawned per request, hard concurrency cap), `template.ts`, `qr.ts`, `fonts.ts`
and `renderCertificate.ts`, with tests and self-hosted fonts. It renders HTML to
PDF from a hand-written fixture.

What is missing is everything around it: nothing stores a rendered PDF, nothing
serves one, and there is no server route that creates or reads a certificate
record.

`shared/schema.ts` is frozen. Read its comments. The load-bearing rule:
**a certificate is an immutable snapshot.** `payload` freezes every resolved
token at issuance, and `certificateAsset` freezes which exact asset version
rendered each slot. Rendering reads `payload` and `certificateAsset`. It must
never re-query `personId`, `courseId`, `cargoId` or `variantId` for wording,
because an edit made after issuance would then change what an already-printed
certificate shows.

## Deliverable 1: PDF storage

Rendered once at issuance, stored, served as a static object, never re-rendered
on read. That is settled; you are choosing the mechanism, not the policy.

**Decision, so you do not have to make it and so it does not add a dependency:**
store on the local filesystem under a directory from runtime config, defaulting
to `.data/certificates`, with the file keyed by verification code. Write through
a small module (`server/storage/`) with a narrow interface (`put`, `get`,
`exists`) so swapping in object storage later is one file. Do not add an S3 or
cloud SDK; do not add any dependency.

Writes must be atomic: write to a temporary name and rename, so a crash mid-write
cannot leave a truncated PDF that later reads treat as valid.

## Deliverable 2: the issued record, server side

`server/api/` routes in your layer:

- Create an issued certificate from a resolved snapshot: allocate the
  verification code if one was not carried over, insert `certificate` and its
  `certificateAsset` rows, render the PDF, store it. The whole thing must be
  atomic in the sense that matters: a `certificate` row must never exist
  pointing at a PDF that was never stored. Decide the ordering that guarantees
  that and write a comment saying why you chose it.
- Read one certificate by verification code, returning the frozen payload.
- Download the PDF by verification code.
- Revoke: sets `revokedAt` and `revokedReason`, gated on `certificate:revoke`
  and on nothing weaker. Revoking never deletes the row or the PDF, and a
  revoked certificate still resolves; it resolves as revoked.

The permission on revoke is not a detail. In the system being replaced, deleting
an issued certificate was guarded by the *read* capability. That is the specific
bug this contract exists to prevent, so do not let revoke share a gate with any
read route.

## Deliverable 3: `/mis-certificados`

The student's own list. One screen, nothing else: what they hold, each with a
download and a shareable verification link. Gated on `certificate:read:own`,
scoped to the signed-in person, SSR, private, never shared-cached. A student
must not be able to reach another person's certificate by changing an id.

Design it as a short list of documents, not a dashboard.

## Deliverable 4: make the renderer real

`renderCertificate` currently renders from a fixture. Give it the path from a
stored `certificate` row plus its `certificateAsset` rows to a rendered PDF, and
prove it end to end against seeded data: `pnpm db:seed` puts one issued
certificate in the database. Render that one, open the PDF, confirm the name,
the gendered cargo label and the dates match `payload`.

Hold it to the budget in the design notes: under 2 seconds at the 95th
percentile, measured at issuance. Report the number you actually measured.

## Not yours

Pre-issue, release, staleness and the fingerprint comparison belong to
`layers/issuance`, which is frozen for you. You expose the creation route; the
issuance state machine calls it. The public `/verificar/:code` page belongs to
`layers/verification`, also frozen. You provide the read route it will consume.
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
