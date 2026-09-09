# Mature Nuxt full-stack repositories worth reading

Survey of production-grade open source Nuxt full-stack repositories, to be read as
architectural references before designing the classroom replacement. Searched by
dependency manifest content rather than repository name or description, because good
Nuxt apps frequently do not advertise the framework anywhere a name search would find.

## Method, and two instructive false positives

GitHub code search against `filename:package.json` across eight dependency families
(`drizzle-orm`, `@prisma/client`, `better-auth`, `nuxt-auth-utils`, `@nuxthub/core`,
`trpc`, `@nuxt/ui-pro`, `vitest`+`playwright`, and the Postgres clients). Candidates were
then filtered on liveness and substance: archived, forked, unmaintained, template-only,
and toy repositories were dropped.

Two repositories that ranked highly by stars are hollow for this purpose and were cut:

- `Barbapapazes/orion` (117 stars, matched four of eight query families) is a template
  aggregator, not a running application.
- `evloghq/evlog` (1,848 stars, very active) is a structured-logging library. Its own
  flagship app does not depend on Nuxt at all; it matched because one adapter package and
  a playground touch Nuxt and NuxtHub.

Both are exactly the failure mode manifest search is supposed to catch and does not: the
dependency is present, the architecture is not.

## Shortlist

1. **hirotaka/pragmatic-nuxt** - 168 stars, commit 2026-09-08, MIT.
   Not a product. A deliberate "bulletproof-react for Nuxt" reference monorepo, with five
   reference apps swapping form libraries (Formwerk, Pinia Colada, TanStack Form,
   VeeValidate) against one coherent core. Worth taking: the dual-adapter
   `server/db/schema.postgresql.ts` + `schema.sqlite.ts` pattern (Neon in production,
   pglite/libSQL in tests), Vitest with Testing Library and Playwright stacked together,
   a shadcn-nuxt/reka-ui component layer, NuxtHub and Wrangler deploy config.
   **Read this one first.** It exists to let you compare valid approaches before committing.

2. **CaoMeiYouRen/caomei-auth** - 218 stars, commit 2026-09-05, MIT.
   A real self-hosted unified-login platform: OAuth2 provider, SSO, email, username, phone
   and social login. Worth taking: production `better-auth` integration including
   `@better-auth/sso`, an admin route namespace kept separate from user-facing auth,
   Postgres via `pg` with Redis for session and rate-limit state, and a Drizzle naming
   strategy module. Directly relevant if certification ever needs SSO or must act as an
   OAuth provider for partner institutions.

3. **linkcraftstudio/feedlog** - 131 stars, commit 2026-09-08, MIT.
   Feedback and changelog SaaS, self-hostable on Workers, Vercel or Docker. Worth taking:
   it is packaged as a **Nuxt Layer** with an explicit `#layers/feedlog` alias, so it runs
   standalone or mounts inside a consumer app. That is a strong pattern if certification
   should be a reusable module rather than a monolith. Also `better-auth` with Drizzle,
   Postgres and `pgvector`.

4. **zeitword/zeitword** - 85 stars, commit 2026-08-05, MIT.
   Headless CMS. Worth taking as a counter-example: hand-rolled `nuxt-auth-utils` session
   auth with its own login and password-reset flow rather than `better-auth`, useful if we
   want full control. Multi-tenant organisation model, invitation-token flow, S3-compatible
   upload via presigned URLs.

5. **HugoRCD/shelve** - 455 stars, commit 2026-09-03, Apache-2.0.
   Secrets and environment-variable manager, a genuinely used tool. Worth taking: the
   Turborepo split into shared base, marketing site, product and vault apps. That is the
   right shape once a Nuxt product needs a separate marketing site alongside the app.
   Drizzle, Postgres, `nuxt-auth-utils`, pglite for local and test databases.

6. **Esposter/Esposter** - 23 stars, commit 2026-09-09, Apache-2.0.
   Low stars, deepest engineering practice in the set. Solo-maintained monorepo running
   tRPC, Drizzle, Postgres, Azure Functions for async jobs including dead-letter replay,
   and Pulumi IaC in TypeScript for the whole footprint. Carries `AGENTS.md`, `CLAUDE.md`
   and per-module testing ledgers, an agent-driven documentation discipline worth studying
   given how we work. Read for rigour, not domain: the product is a personal social site.

7. **florianjs/openstock** - 52 stars, commit 2026-03-11, MIT. Young, right at the
   staleness edge. Inventory management on Nuxt 4, NuxtHub and Drizzle. Worth taking: the
   cleanest simple CRUD-with-auth skeleton in the set, with dev-only seed and migrate
   routes and a setup-then-login bootstrap flow.

8. **HugoRCD/nuxt-ui-chat** - 112 stars, commit 2026-09-02, **no LICENSE file**. Flag
   before reusing any code. Streaming AI chat. Relevant only if the platform ever wants an
   assistant feature; shows AI SDK v5 streaming through Nitro.

9. **datagouv/cdata** - 14 stars, pushed today, license NOASSERTION (a LICENSE file exists
   but is not recognised SPDX; check manually). The production frontend for data.gouv.fr,
   the French government open-data platform. Worth taking: this is Nuxt as a
   backend-for-frontend over an external API, not the system of record, and it uses
   `server/routes/` rather than `server/api/` for that thin layer. Heaviest accessibility
   and testing bar in the set, with `@axe-core/playwright` in CI. Not a database or auth
   reference: it owns neither.

10. **activist-org/activist** - 742 stars, commit today, AGPL-3.0. Running since 2021.
    **Caveat: Nuxt frontend over a Django REST backend, not full-stack Nuxt.** Do not use
    it as a server or database reference. Worth taking: frontend discipline. Heavy
    `vue-i18n` with a dedicated localisation guide, `nuxt-security`, Pinia Colada,
    Testing Library with Playwright and axe, and documented style and contribution bars.
    Relevant to us because the replacement is Spanish-language and public-facing.

11. **danielroe/unsight.dev** - 136 stars, commit 2026-09-07, MIT. By a Nuxt core team
    member. Small and idiomatic: NuxtHub, Drizzle, `nuxt-auth-utils`, GitHub App auth via
    Octokit, `unstorage` for caching. Uses UnoCSS rather than Tailwind, a live
    counter-example to the default.

## What recurs, which is the actual signal

- **Drizzle, decisively, over Prisma.** Every survivor uses `drizzle-orm` and
  `drizzle-kit`. Prisma appeared only in starter templates and stale toys, never in a
  repository that passed the liveness and substance filter.
- **`nuxt-auth-utils` or `better-auth`.** Never a hand-rolled JWT scheme, never a
  NextAuth-style port. The choice is between these two.
- **Postgres is the default**, with `@libsql/client` as the recurring alternative when the
  target is Cloudflare.
- **NuxtHub on Cloudflare Workers dominates the indie tier**, then Vercel, then
  self-hosted Docker. Nobody in this list runs a traditional Node server behind nginx.
  Note that this is a property of the sample, not necessarily the right answer for a
  platform holding Peruvian student records.
- **Nitro file-based `server/api/**.<verb>.ts`**, with `admin/` kept structurally separate
  from user-facing routes, and a catch-all when better-auth owns the auth surface.
- **Vitest universally**; Playwright in about half, always with `@nuxt/test-utils`.
- **Zod for validation** nearly everywhere.
- **`@nuxt/ui-pro` is not the community default.** It appeared mostly in official Nuxt-team
  repositories and paid templates, not in the indie products that survived filtering.
  `reka-ui` with `shadcn-nuxt` and Tailwind is the more common stack among real products.
- **Monorepo shape emerges once a project has more than one surface**: apps plus packages,
  pnpm workspaces, Turborepo or changesets.

## Reading order

`hirotaka/pragmatic-nuxt` for the shape of things, then `CaoMeiYouRen/caomei-auth` for what
a real production auth surface looks like, then `HugoRCD/shelve` for how a Nuxt product
splits into a multi-app monorepo once it has more than one front door.
