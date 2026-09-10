# aula-aliases: import by alias, and make the layer boundaries greppable

## The problem

The reference implementation this repository was modelled on, `npmx-dev/npmx.dev`,
imports by alias almost everywhere: 697 alias imports against 66 relative ones.
Aula is the exact inverse. It has **102 relative parent imports and zero alias
imports.**

That is not a style preference. The architecture is vertical slices, and
`AGENTS.md` says a slice reaching into another slice should be visible at review
time. A relative path defeats that. This is a real line in the repository today:

    layers/certificates/server/render/template.ts
      import { gradeToWords } from '../../../courses/shared/grade-to-words'

Nobody reading that sees a layer boundary being crossed. Written as
`#layers/courses/shared/grade-to-words` it is obvious, and
`grep -rn '#layers/' layers/certificates` becomes a complete list of what the
certificates layer depends on.

## What already works

Nuxt 4 already generates the aliases. `.nuxt/tsconfig.{app,server,shared}.json`
each map `#layers/<name>` and `#layers/<name>/*` for all ten layers. You do not
need to configure them for the app, the server, or typecheck. Confirm this
yourself before you start.

`~~/` is the project root and `~/` is `app/`. Use `#layers/<name>/...` for a
cross-layer import, because it names the layer.

## What does not work, and is deliverable 1

Vitest's `unit` project resolves none of it. This has been verified: a probe test
importing `#layers/courses/shared/grade-to-words` fails to resolve under
`pnpm vitest run --project unit`. The `nuxt` project is fine, because
`defineVitestProject` inherits Nuxt's resolution.

So the first thing you do, before converting a single import, is teach
`vitest.config.ts` the same aliases, and prove it with a probe test that you then
delete. Derive the alias map from the layer directories rather than hand-listing
ten entries that will drift.

**Do this first and confirm the full suite still passes at 98 tests. If the
foundation is not in place, every conversion you make afterwards breaks the
suite, and you will not know which change did it.**

## Deliverable 2: convert the imports you own

You own the repository root config files, `server/`, `app/`, and these seven
layers: `auth`, `people`, `base`, `verification`, `secretariat`, `fulfilment`,
`issuance`.

**You do not own `layers/catalog`, `layers/courses` or `layers/certificates`.**
Three agents are building in those right now. Do not touch them, do not convert
them, do not report them as missed. They get converted when they land, cheaply,
because your foundation will already be in place.

Rules for the conversion:

- A **cross-layer** import becomes `#layers/<name>/...`. Always. This is the one
  that matters.
- An import from the project root (`server/`, `shared/`) becomes `~~/...`.
- An import between close siblings **inside one layer** may stay relative when
  it is a single `./` hop. `./format-date` is clearer than a nine-character
  prefix. Convert `../` and deeper.
- Do not change behaviour. This is a mechanical change and the suite must be
  identical before and after: 98 tests passing, same names.

`server/database/schema.ts` alone has seven relative imports reaching into
layers. It is the clearest single win.

## Deliverable 3: the gate

A convention that is only written down decays. Add an ESLint rule that makes a
cross-layer relative import an error, so this cannot regress and so the three
layers you are not converting will fail lint until they are converted.

Use `no-restricted-imports` with a pattern that catches a relative path escaping
its own layer (`../../`+ from inside `layers/*/`). Verify it fires: point it at
a deliberately wrong import, see the error, remove it.

Because the three live layers will still have relative imports when you finish,
the rule must not break `pnpm lint` on master the moment you land. Resolve that
by scoping the rule to the directories that are converted, with a comment naming
the three that are pending and stating that the scope is removed when they land.
Do not weaken the rule to a warning; a warning is how this decays.

## Verification

`pnpm test` must report the same 98 passing tests it does now. `pnpm typecheck`,
`pnpm lint` and `pnpm build` must pass. Then run `pnpm dev` and load one page
that you converted, because a build passing is not proof a runtime alias
resolved.

Report the before and after counts of relative parent imports.
## Ground rules (identical for every wave-two task)

Read `AGENTS.md` at the repository root first. It states the architecture decisions
you are building inside, not suggestions.

**You own the paths listed above and nothing else.** Unlike the other wave-two
tasks you *do* own `vitest.config.ts` and `eslint.config.mjs`, because the
foundation for this convention lives in them. You still must not touch
`package.json`, `pnpm-lock.yaml`, `nuxt.config.ts`, `tsconfig.json`,
`drizzle.config.ts`, `drizzle/`, or the three layers under live construction.

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
