# Aula: product and architecture decisions

The new application replacing CICAT's Moodle. Decisions, not options. The captain's brief
is a refined and complete site that feels fast and modern, with no legacy UI or UX carried
across.

Grounded in reading two reference implementations, cloned and inspected rather than
summarised: `npmx-dev/npmx.dev` (Nuxt 4, a production app whose own tagline is "a fast,
modern browser for the npm registry") and `hirotaka/pragmatic-nuxt`.

## 1. What "fast" actually means here

The most useful thing in npmx is that its speed is almost entirely a **caching
architecture**, not an animation budget. Reading `nuxt.config.ts` and
`server/plugins/payload-cache.ts`:

- Every route carries an explicit rule. Static pages prerender. Volatile API routes get
  ISR with a short expiry and an **allowlist of query parameters** that participate in the
  cache key (`passQuery` with `allowQuery`), so an unbounded query string cannot poison or
  fragment the cache.
- Content that is versioned and therefore immutable gets
  `Cache-Control: public, s-maxage=31536000, stale-while-revalidate=31536000`. A year.
- A custom Nitro plugin caches the **serialized payload** of an ISR page render. When the
  client then requests `_payload.json` for that route during a client-side navigation, the
  plugin answers from cache in `render:before` and **skips the Vue SSR render entirely**.
  It keys on build id so a deploy invalidates everything, and it serves stale within a
  grace window to survive the race where the HTML came from the edge cache just before the
  payload entry expired.

That is the whole trick, and it transfers directly, because our domain has an unusually
good cache story hiding in it.

**Decision: the same architecture, tuned to our data.**

| Surface | Rule | Why |
|---|---|---|
| `/verificar/:code` | Immutable. One-year `s-maxage` with SWR. | An issued certificate never changes. This is the highest-traffic public surface, hit by anyone scanning a printed QR, and it should be a cached document, not a database query. |
| Issued certificate PDF | Rendered once at issuance, stored, served as a static object. Never re-rendered on read. | Already the semantics of the existing `payload` snapshot. |
| `/cursos`, public catalogue | ISR, 300s. | Changes rarely, read often. |
| Student certificate list | SSR, private, no shared cache. | Per-user. |
| Secretariat console | SSR, private, no cache. Data fetched per interaction. | Authenticated, always fresh, and low-traffic relative to the public surface. |
| Pre-issue batch status | Polled or streamed, never cached. | Live during an exam window. |

The consequence worth stating plainly: the public half of this site can be almost entirely
static, and the authenticated half is small and low-traffic. That is what will make it feel
instant, and it costs nothing but discipline about route rules.

**Rejected: a client-side SPA shell with a loading spinner on every view.** That is what
makes modern web apps feel slow, and it is what Moodle already does badly.

## 2. Structure: vertical slices as Nuxt layers

`pragmatic-nuxt` organises `apps/bulletproof-nuxt` not as one `components/` pile plus one
`server/api/` pile, but as `layers/{auth,base,comments,discussions,teams,users}/`, each
containing its own `app/`, `server/` and `shared/`.

**Decision: the same, with our domains.**

    layers/base/          design system, tokens, primitives, layout shells
    layers/auth/          sessions, roles, permissions
    layers/people/        students, external recipients, profile fields
    layers/catalog/       cargos, variants, rules, assets  (the certificate content model)
    layers/issuance/      pre-issue, release, reconciliation, staleness
    layers/certificates/  rendering, storage, the issued record
    layers/verification/  the public verify surface
    layers/secretariat/   the operator console
    layers/fulfilment/    physical certificate requests and shipping

A layer owns its schema, its server routes, its components and its types together. The
reason this matters more than tidiness: `rebuild-scope.md` shows the current system's worst
coupling is a foreign key from the secretariat panel straight into `mod_feedback`'s
internals. Vertical slices make that kind of reach-across visible at review time, because
it shows up as an import across a layer boundary.

**Rejected: a monorepo with separate apps.** There is one product and one front door.
`shelve`'s multi-app split earns its keep when a marketing site and a docs site exist
alongside the product. That is not this, yet.

## 3. The screens

No Moodle UX survives. What the current system does, per `rebuild-scope.md`, is three tabs
of raw tables with emoji buttons and client-side filtering, plus a Feedback activity abused
as a request form. The replacement:

**Public**

- `/verificar/:code` — the certificate verification page. The single most important screen
  in the product, because it is what a stranger sees when they scan a printed QR. It shows
  the holder, the course, the role, the dates, the issuing authority, and a clear
  authentic-or-not verdict. Fast, static, and legible on a phone. It should look like a
  document, not a dashboard.
- `/` — what CICAT is and what it certifies. Course catalogue.

**Student**

- `/mis-certificados` — a list of what they hold, each downloadable and each with a
  shareable verification link. Nothing else. Students do not need a dashboard.

**Secretariat** — the operator console, and the real product

- `/panel` — one searchable table of every issued certificate across all courses, with
  filter state encoded in the URL so a view is shareable and the back button works.
- `/panel/emision/:curso` — the pre-issue workspace for a course: who is enrolled, who has
  taken the exam, who is pre-issued, who is released, what is stale. Live during an exam
  window. Bulk actions with a visible queue, never a synchronous request that blocks.
- `/panel/entregas` — the physical fulfilment queue, as a first-class entity with real
  states, not parsed out of survey free text.
- `/panel/personas/:id` — edit a person. Owned by this app, not a round-trip into someone
  else's user form, which is the entire reason the current system needs a core patch.

**Admin**

- `/admin/catalogo` — cargos and their gendered labels, variants, rules, assets.
- `/admin/plantillas` — the certificate designer and preview.

**A command palette is the primary navigation for staff.** The secretariat works by
looking for a person or a course. Cmd-K, type a name or a DNI, land on the record. That
single interaction replaces most of what the current three-tab console does, and it is the
clearest expression of "fast and modern" available in an app of this shape.

## 4. Design system

Tokens, typefaces and the four load-bearing details are settled in `design-language.md` and
adopted wholesale: off-white and off-black base (`#fbfbfb` / `#171717`), one accent
(`#103dff`) used as signal and never as fill, monospace for UI chrome and metadata rather
than only for code, a radius ceiling around 6px, the tight contact shadow with an inset
white highlight reserved for genuinely elevated surfaces, and flat 1px borders on
everything that repeats.

Components are hand-rolled on Tailwind v4 with CSS custom properties, using reka-ui only
for primitives that need real accessibility engineering: dialog, popover, select, combobox,
menu, tooltip. Fonts self-hosted through `@nuxt/fonts` with `provider: 'local'`, which is
what npmx does for Geist and Geist Mono and what generates metric-matched fallbacks so
there is no layout shift.

Dark mode through `@nuxtjs/color-mode` writing `data-theme` on the root element, with
tokens keyed off that attribute rather than `prefers-color-scheme` alone, so a user can
override the OS.

One domain-specific note. The certificate itself is a designed artifact with its own
typography, and it is rendered by the same engine that renders the site. The verification
page should show the certificate, not a table describing it.

## 5. Stack

Settled in `nuxt-stack-2026.md` and unchanged: Nuxt 4.5.x with the `app/` directory, plain
Nitro routes with Zod, Drizzle on the stable 0.45.x line over Postgres, better-auth
self-hosted, self-hosted Docker on a VPS in or near Peru, Vitest over server logic with a
thin Playwright happy path.

PDF rendering is settled: **headless browser, HTML to PDF, one pooled warm instance inside
the server process, never spawned per request, with a hard concurrency cap.** The font
licences are being bought, so the constraint that argued for PDFKit is gone. This choice
also means the certificate template is HTML and CSS, which is why the verification page can
show the real artifact rather than a description of it.

## 6. What is deliberately not being rebuilt

Per the strangler shape in `rebuild-shape.md`, Moodle keeps courses, quizzes, enrolment and
Zoom, and this application consumes completion events from it. The integration is one
inbound boundary, and it needs its own retry and reconciliation design because an in-process
event observer is being replaced by a network call. That is the main new risk this
architecture introduces and it should be built with a reconciliation sweep from the first
day, not bolted on after the first missed release.

## 7. Performance budget

Numbers to hold the work to, rather than adjectives:

- Verification page: served from cache, under 100ms to first byte, under 50KB of JavaScript.
  It must work with JavaScript disabled, because it is a document.
- Any staff navigation between cached routes: no visible loading state.
- Certificate render: under 2 seconds at the 95th percentile, measured at issuance, not on read.
- Pre-issue of a 200-student course: queued and progress-reported, never a blocking request.

## 8. Open, and genuinely blocking

One item, from `rebuild-shape.md` S5: whether the Moodle courses carry real teaching or
exist only to gate certificates. It needs a query against the live database. If teaching is
vestigial, the strangler's two-system cost stops being worth paying and the assessment
piece folds into this application. Everything above holds either way; only the boundary in
section 6 moves.
