# Nuxt stack decisions, September 2026

Research into current versions and the state of each layer, for a clean-slate,
self-hosted certification platform holding Peruvian student data. Evidence is live
`npm view` output, the npm downloads API, and official docs read on 2026-09-09.

## Summary

| Area | Recommendation | Named cost |
|---|---|---|
| Nuxt core | Nuxt 4.5.x with the `app/` directory | one more major migration when Nuxt 5 lands |
| Server | Plain Nitro routes plus Zod | revisit oRPC only if an external consumer appears |
| Database | Drizzle on the stable 0.45.x line | more explicit query code, weaker tooling than Prisma Studio |
| Auth | better-auth, self-hosted | young and fast-moving, pin versions; SSO tier unconfirmed |
| UI | reka-ui plus Tailwind v4, hand-built | real weeks of extra build time versus `@nuxt/ui` |
| Deployment | Self-hosted Docker, Node and Postgres, VPS in or near Peru | full ops burden: backups, patching, monitoring |
| Testing | Vitest on server logic, thin Playwright e2e | no UI regression coverage until the design settles |
| PDF | Puppeteer or Playwright, HTML to PDF, pooled instance | 100-300MB held resident, concurrency must be capped |

## 1. Nuxt core

`nuxt@4.5.2`, released 2026-08-05. Nuxt 3 (`3.21.11`) is still patched but is the legacy
line. No Nuxt 5 alpha or RC exists yet.

Version 4 moves `components/`, `pages/`, `layouts/` and `composables/` under `app/`, while
`server/`, `public/` and `modules/` stay at the root. `useFetch` and `useAsyncData` calls
sharing a key now share refs and clean up on unmount, which is a real behaviour change.
Bundles Vite 8.2.x. Note that Nuxt 4 still runs on **Nitro v2** (`nitropack@2.13.4`), not
Nitro v3.

The imminent risk is that Nitro v3 is in public beta and Nuxt 5 is roadmapped for roughly
Q4 2026 to adopt it along with h3 v2. That is not a committed date. Blocking a greenfield
build on an unreleased major with a moving beta dependency is a worse trade than doing a
routine bump later.

**Decision: Nuxt 4.5.x with the `app/` layout.** Mitigate the eventual Nuxt 5 migration by
keeping server code on web-standard Request and Response rather than Nitro-v2-specific
APIs.

## 2. Server layer

Nitro 2.13.4 gives file-based `server/api` and `server/routes`, middleware, auto-imported
utilities, a storage abstraction over 20-plus drivers, and route caching with SWR.
Deployment presets are auto-detected, with `node-server` as the fallback, which is the
right target for self-hosted Docker.

Nitro already generates end-to-end types for `server/api` routes consumed through typed
`$fetch` and `useFetch`, with no extra library. tRPC (`@trpc/server@11.18.0`) and oRPC
(`@orpc/server@1.15.0`) add OpenAPI generation and formal contracts, but only earn their
place once there is an external consumer. There is not one here: a single Nuxt-owned client.

**Decision: plain Nitro routes with Zod validation.** Revisit oRPC, for its OpenAPI story
specifically, if a partner institution integration ever needs a documented public contract.

## 3. Database and ORM

Drizzle: `drizzle-orm@0.45.2` stable, with `1.0.0-rc.5` cut but not GA. `drizzle-kit@0.31.10`.
About 76.5M downloads a month.

Prisma: `prisma@8.0.0-rc.13` currently holds the `latest` npm dist-tag, ahead of stable
`7.10.0`. The 8.x RC series has broken its own API between release candidates - rc.4
dropped the old config format, rc.7 renamed `.take()`/`.skip()` to `.limit()`/`.offset()`.
Churn inside a release candidate is a signal. Prisma 7 replaced the Rust query engine with
a TypeScript and WASM one, which solves an edge and serverless problem a self-hosted VPS
does not have.

Kysely (`0.29.5`, ~59.9M/mo) is the real third option but suits querying an existing
schema rather than a greenfield app that owns its schema.

**Decision: Drizzle on the stable 0.45.x line, with the `postgres.js` driver.** Migrations
are readable committed SQL, which is auditable, and that matters for student records.
Plan the 1.0 upgrade once it leaves RC.

## 4. Auth

Release cadence: `better-auth@1.7.3` published 2026-09-06, roughly weekly, ten releases in
the last month. `nuxt-auth-utils@0.5.30` goes months between patches.
`@sidebase/nuxt-auth@1.3.1` last published 2026-06-30.

Downloads over 30 days: better-auth 27.9M, nuxt-auth-utils 419K, @sidebase/nuxt-auth 182.7K.
Two orders of magnitude between the leader and the other self-hosted options.

better-auth ships an Organization plugin covering multi-tenancy, members and custom
roles, which is RBAC, and an SSO plugin covering OIDC with auto-discovery, OAuth2 and
SAML 2.0. It has a dedicated Nuxt module with SSR-safe sessions. `nuxt-auth-utils` is a
minimal session and cookie helper with no RBAC or SSO. `@sidebase/nuxt-auth` wraps
Auth.js and is visibly slower-moving.

Hosted options (Clerk, Supabase, WorkOS) were not pursued: routing Peruvian student data
through a third-party auth SaaS raises a data-processor question the self-hosting
constraint already answers.

**Decision: better-auth, self-hosted.** Cost: it is young in this shape, with real churn
risk between minors, so pin versions and read changelogs before upgrading. Self-hosting
SAML correctly is hard regardless of library; budget security review for that plugin.

**Unresolved:** whether better-auth's enterprise SSO, SAML and SCIM tier is free and
self-hostable or gated behind a paid Better Auth Cloud product. The docs are ambiguous.
Confirm before architecting institutional SSO around it.

## 5. UI

`@nuxt/ui@4.11.1` (2026-09-07). `@nuxt/ui-pro@3.3.7` last published 2025-10-23 and is
effectively frozen: Nuxt UI v4 merged Pro into the free MIT core, 125-plus components and
dashboard blocks, after NuxtLabs joined Vercel. Peer dependency confirms Tailwind v4 only
(`tailwindcss@4.3.3`). Built on `reka-ui@2.10.4` (~6.8M/mo, roughly three times Nuxt UI's
own usage, so far more people use Reka standalone) with Tailwind Variants theming.
`shadcn-vue@2.8.2` is a CLI that copies component source built on reka-ui into your
repository; it is not a runtime dependency.

On whether Nuxt UI is a straitjacket: it themes at the token and slot level, but every
component shares Nuxt UI's spacing rhythm and interaction anatomy. A retheme still reads
as a Nuxt UI site, the way Bootstrap sites stay recognisable. reka-ui with shadcn-vue
inverts that: headless, accessibility-correct primitives plus markup you own outright.

**Decision: reka-ui and Tailwind v4 directly, using shadcn-vue's CLI to bootstrap
primitives as starting markup, then hand-restyled.** Cost, and this is the largest single
tradeoff in the stack: roughly 125 ready-made components and dashboard blocks forgone,
meaning real weeks of extra build time, and accessibility correctness becomes ours,
mitigated by reka-ui's primitives already being tested. If timeline pressure dominates, a
middle path is Nuxt UI for internal admin screens and hand-built primitives only for
public-facing certificate and branding surfaces.

## 6. Deployment and data residency

**NuxtHub is being wound down.** The managed admin dashboard was sunset 2025-12-31 and
CLI and GitHub Action deploys stop working after 2026-02-02. What remains is self-hosting
on your own Cloudflare account through Wrangler. Cloudflare Workers cannot run Postgres
directly; it needs Hyperdrive proxying to an externally hosted Postgres, and there is an
open unresolved bug (`nuxt-hub/core#867`) where build-time migrations break on a
Hyperdrive-only config. Immature for an app that owns a Postgres database.

Vercel has solid Nitro support but no South American compute region of its own; the
nearest is São Paulo. Its Postgres is Neon-backed and hosted outside Peru regardless.

On latency: AWS opened a Direct Connect location in Lima in 2023. Cloudflare has a Lima
PoP, its fourth in Latin America, though one community RTT measurement came back around
80ms rather than the expected 10ms, so it is peering-dependent.

On compliance: Peru's Ley 29733, as updated by DS 016-2024-JUS effective 2025-03-30, does
not clearly mandate in-country residency but requires data-processor contracts and permits
cross-border transfer only to jurisdictions deemed adequately protective. Every extra
platform layer is a separate processor needing its own contract review. A self-hosted VPS
collapses that chain to one.

**Decision: self-hosted Docker Compose, Node plus Postgres, on a VPS in or near Peru,
using Nitro's `node-server` preset with Postgres colocated.** Cost: the full ops burden -
patching, backups (plan pgBackRest or cron plus object storage from day one), TLS,
connection pooling, uptime monitoring - and no edge network for static assets.

## 7. Testing

`@nuxt/test-utils@4.3.2` requires Vitest 4 or later and replaced vite-node with Vite's
Module Runner. `vitest@5.0.0` is now `latest`. `@playwright/test@1.63.0`.

**Decision for day one: Vitest unit tests over server-route business logic**, especially
auth and role checks and certificate data assembly, since a bug there is either a security
hole or a wrong credential handed to a student. Plus one Playwright end-to-end happy path
per critical flow: login into a role-gated page, and the full certificate generation flow
including asserting the returned file is a real PDF. Skip broad component testing and wide
e2e coverage; that layer is the most likely to be rewritten once the UI direction settles.
Cost: deliberately thin, and it will not catch UI regressions.

## 8. PDF generation

| Option | Version | Note |
|---|---|---|
| pdf-lib | 1.17.1 | **Abandoned upstream, last published 2021-11-06.** Do not use. |
| @cantoo/pdf-lib | 2.9.2 | Maintained fork of the above, same API, adds SVG. |
| @react-pdf/renderer | 4.9.0 | Real layout engine, good font handling, but templates in JSX - a second UI paradigm inside a Vue codebase. |
| Puppeteer | 25.10.0 | Full HTML and CSS surface, best layout fidelity, trivial accent handling. 100-300MB per warm instance, ~300MB Chromium binary. |
| Playwright | 1.63.0 | Same profile as Puppeteer. |
| Typst | no stable npm package | Excellent typesetting, light and fast, but a new markup language and an immature Node binding. |
| LaTeX | shell out | Best quality, multi-second compiles, 4GB-plus install, fragile. |
| PDFKit | 0.20.2 with fontkit 2.0.4 | Both maintained. Manual coordinate layout, light footprint. |

**Decision: Puppeteer or Playwright rendering an HTML and CSS certificate template,
running as a pooled warm browser inside the Nitro process, never spawned per request.**
Certificates here are low-volume and high-design-value, which is exactly where HTML and
CSS flexibility beats a headless browser's overhead: background image, precise
positioning, QR code as inline SVG, trivial Spanish accents. Cost: 100-300MB resident plus
the discipline of a singleton browser manager and concurrency caps to avoid OOM on a
modest VPS. Fallback if volume becomes a problem: PDFKit with fontkit, at the price of
hand-computed coordinates.

Note this bears directly on the four TCPDF fonts. An HTML-to-PDF route needs them as web
fonts, which is a conversion and licensing question, not a code question.

## Deferred, needs a human decision

1. Whether Ley 29733 as amended imposes hard in-country residency, which decides whether
   the VPS must be physically in Peru or merely in the region.
2. Whether better-auth's enterprise SSO, SAML and SCIM tier is free and self-hostable.
3. Real Lima-to-candidate-region latency. Measure it; do not trust vendor marketing.
