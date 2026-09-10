# aula-hygiene: a dead dev server, em dashes, and the gates that missed both

Three defects that share one property: every existing check reported green.

## Deliverable 1: `pnpm dev` is broken on master, fix it and gate it

`layers/catalog/server/api/admin/catalog/permission-check.test.ts` is a **test
file inside a `server/api/` directory**. Nitro scans that directory as its route
tree, imports the file as a route module, and the `vitest` import throws:

    ERROR [uncaughtException] Vitest failed to find the runner.
    - "vitest" is imported directly without running "vitest" command

The server then exits. Every route returns nothing. This has been verified by
hand: `pnpm dev` boots, then dies on the first request, and `curl` to `/`,
`/cursos` and `/api/cursos` all fail to connect.

`pnpm test`, `pnpm lint`, `pnpm typecheck` and `pnpm build` **all pass** on this.
None of them start the server, so nothing noticed that the application does not
run.

Move the file to `layers/catalog/test/`, matching where every other layer keeps
its tests, and confirm `pnpm dev` then serves.

Then make it unrepeatable. A test file under any `server/api/` tree must fail a
check, not wait to be discovered by someone running the dev server. Add that as
a lint rule (`files`/`ignores` in `eslint.config.mjs` can express "no
`*.test.ts` under `layers/*/server/api/**`"), so `pnpm lint` refuses it.

## Deliverable 2: a smoke check, because "builds" is not "runs"

The gap above is the real finding. Add a `smoke` script that boots the built
application, requests a small set of routes, asserts each returns the status it
should, and shuts down cleanly with a non-zero exit on any failure.

Cover at least: `/` (200), `/cursos` (200), `/verificar/<a code that does not
exist>` (404, and it must be the designed not-found page rather than a crash),
and one authenticated route returning 401 when called with no session.

Wire it into `.github/workflows/ci.yml` as a step after the build. Keep it fast
and dependency-free: `node`, and the `playwright` already installed, are
available; do not add a package.

Expose it the way every other command in this repo is exposed, as a `package.json`
script alongside `dev`, `test`, `lint`, `typecheck` and `build`.

## Deliverable 3: remove the em dashes

`AGENTS.md` says to use a period, comma, colon or parentheses instead of an em
dash. **Master has 38 of them**, in comments, page titles and UI strings:

    layers/courses/app/pages/cursos/[code]/notas.vue:90   Notas — {{ data.course.name }}
    layers/catalog/app/pages/admin/catalogo/variantes.vue:3   title: 'Variantes — Aula'
    layers/certificates/.../mine.get.ts:7   * signed-in person server-side — there is no id

Replace every one. This is a judgement call per site, not a blind substitution:

- In a page title, a middle dot or a colon usually reads better than a hyphen.
- In prose and comments, restructure into two sentences, or use a comma, colon
  or parentheses. Do not simply swap in a hyphen where the sentence wanted a
  break.
- In a Spanish date range, `al` is the natural word, and it matches the seeded
  variant body text (`del {{fecha_inicio}} al {{fecha_fin}}`).

Then add an ESLint rule making an em dash an error, so CI enforces what
`AGENTS.md` asks. `cap check` already catches em dashes on **added** lines, but
it cannot see the ones already on master, and it is not part of CI.

Do this as its own commit, separate from the two behavioural fixes above.

**`layers/fulfilment` is being built by another agent right now. Do not touch
it, including its em dashes.** They will be caught on that branch. Scope your
ESLint rule so `pnpm lint` stays green on master when you land, and say in your
report that fulfilment still needs the pass.

## Verification

`pnpm test` (165 now, must not shrink), `pnpm lint`, `pnpm typecheck`,
`pnpm build`, and your new `pnpm smoke`.

Then the check that started all this: run `pnpm dev`, and `curl` `/`, `/cursos`
and `/api/cursos`. Report the actual status codes. A green test suite is not
evidence the server runs, which is the whole lesson here.
## Ground rules (identical for every wave-two task)

Read `AGENTS.md` at the repository root first. It states the architecture decisions
you are building inside, not suggestions.

**You own every layer except `layers/fulfilment`, plus `server/`, `app/`,
`package.json`, `eslint.config.mjs` and `.github/`.** You need `package.json`
for the `smoke` script; that is the one task in this project allowed to touch
it, so add the script and change nothing else in it.

Frozen: `layers/fulfilment` (live), `pnpm-lock.yaml`, `nuxt.config.ts`,
`tsconfig.json`, `vitest.config.ts`, `drizzle.config.ts`, `drizzle/`.

Three consequences, each of which has bitten this repository before:

- **No new dependencies**, and do not run an install. Everything you need is installed: `drizzle-orm`, `zod`,
  `reka-ui`, `qrcode`, `better-auth`, Tailwind v4, Vitest, Playwright. If you
  genuinely need one more, stop and report it instead of editing the manifest.
- **No schema changes at all.** Nothing here needs one.
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
