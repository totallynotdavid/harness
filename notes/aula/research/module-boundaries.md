# Where do module boundaries go in a one-database app?

## The verified graph

I re-derived the dependency graph from the repo directly rather than trusting the summary. Two refinements:

**The schema-to-schema (FK) graph is a clean DAG, not a mesh.** Grepping every `layers/*/shared/schema.ts` for `#layers/` imports gives:

```
auth       -> people
courses    -> people
catalog    -> people, courses
certificates -> people, courses, catalog
fulfilment -> certificates
issuance   -> people, courses, catalog, certificates
```

No schema file imports from `catalog` back into `certificates`, and no schema file imports from `certificates` into `issuance`. The **catalog → certificates** edge you measured is real but is not a schema dependency at all — it's `layers/catalog/server/api/admin/catalog/sample.get.ts:2` importing a pure date-formatting function, `formatDateEs`, from `#layers/certificates/shared/format-date`. One utility function, no table, no FK.

**The certificates ↔ issuance cycle is real, and it is not symmetric in kind.** `layers/issuance/shared/schema.ts:5` imports `certificate` — that's the schema-level edge, and it's one-directional: `issuance.certificateId references certificate.id` (`layers/issuance/shared/schema.ts:60`). The reverse edge, `layers/certificates/server/api/certificates/index.post.ts:2` importing the `issuance` table, is not a foreign key at all. It's a route handler doing a uniqueness check: verification codes must not collide across *either* table, because — per the schema's own comment — `issuance` is explicitly "the pre-issue shadow record" of the same code that becomes a `certificate` row on release (`layers/issuance/shared/schema.ts:24-32`). The cycle exists because one shared invariant (global uniqueness of a verification code) is enforced by application code reaching across a boundary that was drawn through the middle of a single record's lifecycle, not because two unrelated entities happen to reference each other.

So: 1 real FK-level cycle (certificates/issuance, asymmetric — one FK, one invariant-check reach-across), 1 non-cycle (catalog/certificates, a one-line utility import), and everything else in the schema is a DAG rooted at `people`.

---

## 1. What does the Nuxt team say layers are for?

Fetched via Context7 (`/websites/nuxt_4_x`, high-reputation source, docs at nuxt.com/docs/4.x):

> "The `layers/` directory allows you to organize and share reusable code, components, composables, and configurations across projects. Layers placed in this directory are automatically registered." — [directory-structure](https://nuxt.com/docs/4.x/directory-structure)

> "Nuxt layers allow extending a default Nuxt application to reuse components, utils, and configurations... Common use cases include sharing configuration presets, building component or composable libraries, creating themes, and **supporting modular Domain-Driven Design (DDD) architectures** in large-scale projects." — [getting-started/layers](https://nuxt.com/docs/4.x/getting-started/layers)

That second line is the strongest textual peg for aula's design — the docs do use the phrase "DDD." But the only worked DDD-flavored example the docs give is this, from the components-scanning config:

```ts
components: [{ path: '~/domains', pattern: '*/components/**', pathPrefix: false }]
// ~/domains/blog/components/PostCard.vue => <PostCard />
```

That's Vue component discovery, not data ownership. Nowhere in the fetched pages (getting-started/layers, guide/going-further/layers, directory-structure) is a database, ORM, schema, or Nitro data layer mentioned. The named `#layers/<name>` alias — the exact mechanism aula uses for cross-layer imports — is documented as existing "to avoid referencing issues across layer **components and composables**" (going-further/layers). Aula uses that same alias to import Drizzle table objects, which the docs never depict as a use case.

Layer composition itself (`extends` in `nuxt.config.ts`) is a **priority-ordered override system** — each layer is a nearly-complete Nuxt app tree, and later layers can override earlier layers' files by filename collision (docs: "layers with higher priority override lower-priority layers when defining the same files or components"). That's a mechanism for config/theme/template *inheritance*, not for peer modules with mutual runtime dependencies. Nothing in the fetched docs discusses import cycles between layers, because the composition model doesn't anticipate peer layers needing each other's internals at all — it anticipates a project extending a starter/theme.

**Conclusion for Q1:** Nuxt positions layers primarily as config/asset/component sharing across projects (themes, starters, npm-installable presets), with one line asserting they also "support" DDD-style organization for large single-project apps. That one line is real, but the docs' own example of what that looks like is UI-component folder structure, not database schema, and the specific alias mechanism aula repurposed for schema imports is documented as being for components/composables.

## 2. Do real large Nuxt/Nitro codebases slice a database schema per layer?

I had an agent search GitHub, Nuxt's own official repos, and the NuxtHub docs. Findings:

- **`nuxt/nuxt.com`** (Nuxt's own website, official repo): has exactly one layer (`layers/nuxi`, the "Eve" AI chat feature) with its own `server/db/schema.ts`. Its tables get a real FK into the host app's `users` table via `import { users } from '#server/db/schema'`. This is a genuine official example of schema split across a layer boundary with a cross-boundary FK — but it is **one feature layer depending upward on the host, one-directional, two schema locations total**. Not a mesh of ~10 peer layers.
- **`harlan-zw/request-indexing`** (Harlan Wilton, Nuxt/Nuxt-SEO ecosystem maintainer): originally had per-layer schema files; the codebase now has only `layers/core/server/db/schema.ts` as the real source, with a re-export-only seam file in `layers/pro-saas` whose comment reads: *"Re-exports the host's drizzle schema (now lifted into `layers/core/server/db/schema.ts`)... never [import] from `~~/layers/core/...` directly."* That's a maintainer documenting a deliberate move **away** from distributed per-layer schema toward one centralized file, specifically to stop layers reaching into each other's schema paths. Separately, a genuine mutual FK (`teams`↔`users`) in that codebase is resolved by keeping both tables in the *same file* with a lazy forward reference (a standard Drizzle circular-FK technique), not by splitting them across modules.
- **NuxtHub docs** (hub.nuxt.com) confirm per-layer schema auto-discovery exists as a *capability* (`layers/cms/server/db/schema.ts` is scanned automatically), but the docs never address foreign keys or cross-layer references — it's presented as a file-discovery convenience, silent on coupling.
- No repo, doc, or blog post was found with three or more peer layers independently owning schema with FKs pointing at each other in a cycle.

**Conclusion for Q2:** Schema-per-layer is not an established pattern in real Nuxt codebases. Where it's used at all, it's one dependent feature-layer pointing one-way at a host app's tables — never a cycle between equals. The one comparable real-world case that tried distributing schema across layers moved back to centralizing it, in writing, because of the exact cross-layer coupling problem aula now has.

## 3. Is a cyclic FK dependency between modules a defect, or expected?

Sourced findings (agent-researched, cross-checked against named, attributable sources — not blog consensus):

- **Vaughn Vernon**, *Effective Aggregate Design*, Part I ([dddcommunity.org PDF](https://www.dddcommunity.org/wp-content/uploads/files/pdf_articles/Vernon_2011_1.pdf)) and *Implementing Domain-Driven Design* ch. 10: "When you find yourself wanting to modify two aggregates in the same [transaction]... that is a signal that either your aggregate boundaries are drawn incorrectly, or the relationship... should be handled through eventual consistency." This is the most direct, named answer to the question: a synchronous cross-boundary dependency to satisfy one invariant is diagnostic of a wrong cut, not a tolerable cost.
- **Chris Richardson**, [microservices.io — Database per Service](https://microservices.io/patterns/data/database-per-service.html) and *Microservices Patterns*: the pattern forbids cross-service foreign keys outright; a real FK relationship is evidence the two tables belong to one service/module, referential integrity across a genuine boundary becomes application-level, not schema-level.
- **Sam Newman**, *Monolith to Microservices*, ch. 4 ("Decomposing the Database"): treats removing a FK across a proposed split as something you must do *when* decomposing, and names it as a real transactional-safety cost being paid — i.e., FK removal isn't free, which cuts the other way: it's evidence the split has a price, not that the FK was safe to leave.
- **Simon Brown**, *Modular Monoliths* (GOTO 2018): modules should own their data and coupling in the data model is something to watch for — weakest-sourced of the group here since he doesn't address cyclic FKs by name.
- I could **not** find any named source (Fowler, Vernon, Evans, Richardson, Brown) asserting that a cyclic FK relationship between modules is an expected, acceptable, or "just how relational schemas work" outcome. That framing exists only in generic, unattributed anti-pattern write-ups (e.g. Wikipedia's circular-dependency entry) — explicitly flagging that as unsourced consensus, not authority, per your instructions.

**Conclusion for Q3:** every named source that speaks to this treats a synchronous cross-module dependency needed to satisfy a shared invariant as a symptom to fix — either by merging the modules or by making the relationship eventually consistent — not as an inherent, acceptable cost of "a relational schema with FKs crossing every boundary." No source disagrees; the only source of the opposing view is unattributed.

## 4. What boundary criterion do the sources recommend?

Named, not adjectives:

- **Vernon / Eric Evans (DDD)**: **transactional consistency of true invariants**. An Aggregate boundary is defined as a single-transaction boundary — everything that must be consistent *right now* goes inside one Aggregate; everything else is a separate Aggregate reached via ID reference and eventual consistency (Vernon, *Effective Aggregate Design*, Part I, "Protect true invariants in consistency boundaries").
- **Richardson**: decompose by **subdomain / business capability**, with "no cross-service foreign key" used as the mechanical test of whether the cut is sound.
- **Newman**: decompose around **business capability / bounded context**; FK removal is a consequence of the cut, not the criterion for making it.
- **Conway's Law** (Melvin Conway, 1968) and **team ownership**, popularized as a boundary lens in Skelton & Pais's *Team Topologies*, is a different, orthogonal criterion (who owns the code) — none of Fowler/Vernon/Richardson/Brown argue it as *the* database-boundary test in the sources checked here, so it doesn't bear directly on your FK-cycle question.

The one criterion with a named source that speaks directly to "should this FK relationship cross a module boundary" is Vernon's: **the boundary should equal the transactional/invariant boundary**, not the noun/entity boundary.

## Recommendation for aula

**Stop slicing the Drizzle schema per layer; keep one schema module, keep the ten Nuxt layers for routes/UI/config.**

Why the evidence supports this:
- Nuxt's own docs never depict database schema as a layer concern — the "DDD" use case they cite is components-only, and the `#layers/<name>` alias aula repurposed for table imports is documented as existing for components/composables (Section 1).
- No real-world Nuxt codebase found splits schema across peer layers with mutual FKs; the one maintainer who tried it (`harlan-zw/request-indexing`) documented moving back to one file specifically to kill this exact coupling problem (Section 2).
- `drizzle.config.ts:15` (`schema: './layers/*/shared/schema.ts'`) and the barrel comment at `server/database/schema.ts:1-4` ("Barrel of every table and enum in the app... exists so a single `schema` object can be handed to `drizzle()`") already show the app treats this as one schema for every purpose that matters to the database itself. The per-layer split is a source-file convention layered on top of something Drizzle-kit and Drizzle's query builder already require to be unified. Consolidating doesn't fight the tool, it stops fighting it.
- Applying Vernon's named test to the actual cycle: `certificate` and `issuance` are two states of one lifecycle sharing one invariant (global verification-code uniqueness), enforced synchronously across the boundary — his criterion says that's exactly the signal to merge them into one consistency boundary, not leave them cyclic. Under one schema module this stops being a violation to route around; it's a design decision to make once, visibly, in one file.
- The catalog↔certificates edge isn't a schema problem at all — it's `formatDateEs` living in the wrong layer. Move it to `base`, independent of the schema decision.

What it costs: the ten-layers-as-bounded-contexts story gets weaker — "each layer owns its slice of the domain end-to-end" was the organizing metaphor, and pulling schema out of it means layers now only own routes/components/business logic, not data. It's also a real migration: ~7 files' imports change, and any future contributor loses the "everything about certificates is under `layers/certificates`" mental model for the one piece (table definitions) that turns out not to respect layer lines. The case against consolidating is that this cost is paid once and the layer split still earns its keep everywhere else in the app (routes, UI, config, `extends` priority) — only the schema slice was ever contradicted by the evidence above.
