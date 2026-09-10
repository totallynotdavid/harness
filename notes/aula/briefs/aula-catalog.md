# aula-catalog: the certificate content model and its admin console

You own `layers/catalog/` and nothing else.

## What already exists

`layers/catalog/shared/schema.ts` defines the whole content model and is frozen:
`cargo` and `cargoLabel` (a printed role plus its gendered Spanish labels and
articles), `variant` (a layout key plus body text with `{{token}}` placeholders),
`rule` (maps a context to a variant; nullable `cargoId` and `courseId` each mean
"any"; lower `priority` wins), `asset` and `variantSlot` (versioned backgrounds,
signatures and stamps, bound to named holes in a layout, per emission mode).

Read the comments in that file. They record why each shape was chosen, and
several of them are load-bearing: assets are versioned and never replaced so an
already-issued certificate keeps rendering exactly as signed, and cargos are
soft-deleted so a retired role still resolves.

## Deliverable 1: `resolveVariant`, the shared primitive

Create `layers/catalog/shared/resolve-variant.ts`. This is the single owner of
rule resolution for the whole application, and `aula-issuance` will import it
from this exact path, so treat the signature as a published contract:

```ts
export interface VariantMatch {
  variantId: string
  ruleId: string
  priority: number
}

export interface ResolveVariantInput {
  cargoId: string
  courseId: string
}

/** Rows are passed in rather than queried, so this stays pure and testable. */
export function resolveVariant(
  rules: readonly { id: string, variantId: string, cargoId: string | null, courseId: string | null, priority: number, active: boolean }[],
  input: ResolveVariantInput,
): VariantMatch | null
```

Semantics: consider only active rules; a null `cargoId` matches any cargo and a
null `courseId` matches any course; among matches the lowest `priority` wins;
ties broken deterministically (specify how in a comment and make it stable, not
insertion-order dependent). Returns null when nothing matches.

Test it as a pure function, including: exact match beats wildcard, wildcard-only
match, inactive rule ignored, priority ordering, no match.

Also create the label helper `layers/catalog/shared/cargo-label.ts`, which picks
the right `cargoLabel` row for a person's gender with a documented fallback when
the exact gender row is missing.

## Deliverable 2: `/admin/catalogo`

Pages in `layers/catalog/app/pages/admin/catalogo/`. Server routes in
`layers/catalog/server/api/admin/catalog/`. Every route gated on
`catalog:manage`.

Four managed collections: cargos (with their gendered labels edited inline),
variants, rules, assets. What matters, in order:

1. **Rules are the hard screen and the one that earns the feature.** An operator
   must be able to see, at a glance, which variant a given cargo-and-course
   combination will actually resolve to. Build a "probe" control: pick a cargo
   and a course, see the winning rule and the variant it selects, and see which
   other rules matched but lost. This is the difference between a rules table
   and a rules editor.
2. Creating a new version of an asset must be an explicit "new version" action
   that inserts a row and flips `active`, never an in-place edit of an existing
   version. Make the version history visible.
3. Retiring a cargo sets `active = false`. There is no delete. Say so in the UI.

Filter and pagination state goes in the URL query string, so a view is
shareable and the back button works.

## Deliverable 3: `/admin/plantillas`

Variant editing with a live preview. The body text carries `{{token}}`
placeholders; show the operator which tokens are available, flag unknown tokens
as errors before saving, and render a preview with the seeded sample person
substituted in.

You are not building the PDF renderer. `layers/certificates` owns that and is
frozen for you. Preview means an HTML preview of the substituted body text and
the resolved slots, not a PDF.

## Route rules

`/admin/**` is already `{ isr: false, cache: false }` in the root config. You do
not need to change it, and you must not.
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
