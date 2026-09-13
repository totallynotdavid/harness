# Aula: the target architecture

Decided 2026-09-11 from the three research reports in `notes/aula/research/`.
Every claim below traces to one of them.

## The one decision everything else follows from

Aula is a **document system that signs its artifact**.

Status lives in CICAT's database and is read live at `/verificar/<code>`. The
integrity of the PDF's bytes lives in the PDF, as a PAdES signature. Neither
half is optional and neither half is the whole answer.

This is not the pure form of either pattern the research found.

A pure document system (Moodle, Open edX, Documenso) treats the database as
everything and the PDF as a disposable view regenerated on demand. That fails
CICAT, because certificates are printed and hand-signed before the exam. A
physical document exists in the world that the database cannot vouch for.

A pure credential system (Boulder, step-ca, W3C Verifiable Credentials) makes
the artifact stand alone so no verifier ever calls the issuer. That costs key
custody infrastructure and a published revocation feed, and it buys
interoperability with an ecosystem CICAT's verifiers are not in. SUNEDU, Peru's
own higher-education regulator, runs the national registry as a code lookup
page. That is the convention every Peruvian employer already knows.

So: the database answers "is this certificate valid right now". The signature
answers "are these the bytes CICAT issued". Different questions, different
mechanisms.

## What is frozen at issuance

A certificate row is immutable after issuance except for revocation. Aula
already freezes the resolved content in `payload` and the exact asset versions
in `certificateAsset`. That is more than Moodle or Open edX do: both resolve
their templates by live foreign key, so editing a template retroactively
changes how already-issued certificates render.

Two things are still missing.

**The renderer is not pinned.** Nothing records which template source or which
typst version produced the bytes. Store a `rendererVersion`: a hash of the
typst template source combined with the pinned typst version. Without it,
"reproduce the certificate we issued in 2026" has no answer in 2031.

**The bytes are not hashed.** `renderedFingerprint` hashes the inputs, not the
output. Store `pdfSha256` on the row. Boulder lint-checks that its signed
certificate matches the planned one byte for byte before storing it. This is
the same check, and it is what makes the object store addressable by hash.

## Verification codes get one allocator

The only real cycle in the layer graph is `certificates` and `issuance`
reaching into each other. It exists because a verification code must be unique
across both tables, and the check is application code crossing the boundary.

Replace it with a `verificationCode` table that owns the code. Both `issuance`
and `certificate` reference it. Uniqueness becomes one database constraint
instead of a query that a future route can forget to run.

Vernon's rule is that a synchronous cross-boundary dependency protecting one
invariant means the boundary is wrong. Here the boundary was drawn through the
middle of a single record's lifecycle. Moving the invariant into the schema
makes the collision unreachable rather than merely checked.

## Schema is one module, layers are not

Tables move to `server/database/schema/`, one file per group. Layers keep
routes, components and business logic.

Nuxt's own documentation never presents database schema as a layer concern.
The `#layers/<name>` alias aula uses to import tables is documented as existing
for components and composables. No real Nuxt codebase was found that splits
schema across peer layers, and the one maintainer who tried it wrote a comment
explaining the move back to a single file.

`formatDateEs` moves to `base`. It is a date formatter living in
`certificates`, and it is the entire reason the graph appeared to have a second
cycle.

## Rendering

Keep typst spawned per render. It is roughly 100 ms, deterministic with a
pinned creation timestamp and `--ignore-system-fonts`, and needs no library
binding. This is the best decision in the current codebase.

Move batch rendering out of the request path. A course of 200 students is 200
sequential renders inside one HTTP request, and a failure halfway through
leaves partial work with no retry. The queue already exists: it is the
`issuance.status` column. Add a pending state, return immediately, let a worker
drain it.

## Storage

PDFs go to object storage, addressed by `pdfSha256`.

Content addressing removes the path-traversal guard in
`layers/certificates/server/storage/index.ts`, because a hash cannot be a
traversal. It makes the stored bytes verifiable against the row. Boulder
publishes its revocation lists to an S3-compatible store for the same
durability reason.

A single Docker volume holding the only copy of every issued certificate is the
current arrangement and it is the largest operational risk in the system.

## Signing

PAdES B-LTA on the PDF at release. ETSI EN 319 142, an ISO and ETSI standard
with no membership fee and no certification gate, unlike Open Badges 3.0, whose
conformance requires paid 1EdTech membership at an unpublished price.

B-LTA embeds the certificate chain, revocation evidence and a trusted timestamp
inside the PDF, so it validates years later even if CICAT's servers are gone.

The signing key does not live in the web application's process. Every credential
system surveyed separates it: Boulder's CA is a separate process reachable only
over gRPC, Fulcio requires KMS or HSM, step-ca can proxy signing to another
instance. Every document system surveyed does not: Documenso and OpenSign both
read a `.p12` from the app server's own environment.

Aula does not need an HSM ceremony at this scale. It does need the key held by
something other than the process serving HTTP, because a web vulnerability
should let an attacker read data, never mint genuine certificates.

## Verification stays live

`/verificar/<code>` reads the database. That is what gives live revocation, and
it is the pattern SUNEDU already established nationally.

Publish the same answer as JSON alongside the page, so an employer checking in
bulk does not have to scrape HTML.

Do not pre-build verification as static files. The earlier argument for that
was reasoning from a serverless deployment, and it trades away the one thing
this endpoint exists to provide.

## Revocation

Keep the current shape: a status plus `revokedAt` and `revokedReason`, never a
delete.

Moodle's `mod_customcert` hard-deletes the issue row, so a revoked certificate
leaves no trace it ever existed. Documenso and OpenSign cannot revoke a
completed document at all. Aula is already ahead of all three, and Open edX's
separate `CertificateInvalidation` audit table is the only surveyed pattern
worth borrowing if revocations ever need an approver and a note.

## Development and deployment

Drop PGlite. Dev uses the Postgres already in `docker-compose.yml`. The
embedded fallback costs 17 MB in the production image and forces `useDb()` to
stay synchronous, to avoid needing a second database engine to run a database
that is already running.

Deploy the Docker image on a server CICAT owns. Migrations stay a release step
through the `tools` compose service.

## Order of work

Ordered by what the rest depends on, not by cost.

1. `rendererVersion` and `pdfSha256` on the certificate row. Nothing else can
   be proved without them, and they depend on nothing.
2. The `verificationCode` allocator table. Kills the cycle.
3. One schema module, and `formatDateEs` to `base`.
4. Object storage keyed by hash.
5. PAdES signing, with the key outside the app process.
6. Batch rendering as a queued job.
7. Drop PGlite.

Items 1 and 2 are both schema changes and should land together.
