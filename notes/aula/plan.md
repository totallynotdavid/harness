# Aula: build plan and team division

Repository `~/git/aula`, registered as project `aula`, mode `local`, model `sonnet`.
Base commit `188d2f7` scaffolds Nuxt 4.5.2 with ten vertical-slice layers, the design
tokens, the route rules, and `AGENTS.md`. `pnpm build` passes on it.

Design decisions live in `notes/classroom/aula-design.md`. Domain evidence lives in
`notes/classroom/rebuild-scope.md`.

## What changed in the shape

The captain answered the one blocking spike: **teaching is not vestigial.** Moodle
courses carry real content, each class has material and a link to a Zoom session. So the
strangler boundary from `rebuild-shape.md` moves. Aula owns courses, classes, materials,
live session links, enrolment and grade capture. It does not rebuild Moodle's quiz engine
on day one; grades are captured and imported, and assessment can grow later.

That matters because certificates are gated on a grade, and the certificate prints that
grade in words. Grade capture is therefore day-one scope, not a later feature.

## On copying the production database

The captain offered a copy from the master server. **Not taking one.** The question it
would have answered, whether teaching is real, has been answered directly. A copy of that
database is 3.6 GB of student personal records, and pulling it onto a development machine
is a privacy cost with no remaining research benefit.

If a schema question comes up during the build, the proportionate move is a **schema-only
dump plus aggregate counts**, never student rows. Migration of real records is its own
task, done once, against the production system, at the end.

## Team division

Four teams in wave one, chosen so no two touch the same files. Each owns whole layers.

| Team | Slug | Owns | Depends on |
|---|---|---|---|
| Schema | `aula-schema` | every `layers/*/shared/schema.ts`, drizzle config, migrations, seed | nothing |
| Design system | `aula-design-system` | `layers/base` entirely | nothing |
| Auth | `aula-auth` | `layers/auth` entirely, its own tables | nothing |
| Rendering | `aula-render` | `layers/certificates` rendering pipeline and template | nothing |

The boundary that keeps these disjoint: Schema owns the domain tables, Auth owns the
tables better-auth generates plus its own role and permission tables. Rendering builds the
PDF pipeline against a hand-written fixture, not against the database, so it does not wait
on Schema.

Wave two, after wave one lands: `catalog`, `courses`, `issuance`, `certificates` record.
Wave three: `verification`, `secretariat`, `fulfilment`.

## Sequencing rationale

Wave one is everything with no upstream dependency. Waves two and three are gated because
they consume the schema and the design primitives. Running them early would mean building
against a moving target and resolving merge conflicts that better sequencing avoids.

## Reference material

- Auth architecture: `~/git/culqi360/apps/web/src/{contracts/auth.ts,domain/auth,server/auth}`.
  Roles as a const tuple, permissions as a `resource:action:scope` string union, session
  classes that gate routes, step-up strong auth, throttling, audit events, retention windows.
- Caching architecture: `npmx-dev/npmx.dev`, cloned to the session scratchpad. Its
  `nuxt.config.ts` route rules and `server/plugins/payload-cache.ts`.
- Layer structure: `hirotaka/pragmatic-nuxt`, `apps/bulletproof-nuxt/layers/`.
- Old domain: `~/git/cicat/classroom/local/{certengine,certpreissue,panel_secretaria}`.
  Reference for the domain only. Nothing about its structure carries over.
