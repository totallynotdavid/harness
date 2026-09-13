All research is in. Compiling the final report now from the verified findings gathered across all twelve systems.

---

# How real credential-issuing systems structure themselves

Method: five parallel agents cloned and read source for 12 systems across five categories, using `gh search repos` to check production signals (stars, commit recency, deployment evidence) and `cap explore` to get code on disk, then citing file:line from schemas/models/key-management code. Two candidates were rejected mid-investigation and are noted below.

## A. PKI / Certificate Authorities (X.509)

### 1. `letsencrypt/boulder` (5,748★, pushed today — issues the majority of the web's TLS certs)

1. **System of record**: split. Immutable DER stored once — `` `der` mediumblob NOT NULL `` (`sa/db/01-boulder_sa.sql:57-68`). Lifecycle state is a separate mutable row: `` `status` varchar(255)``, `revokedDate`, `revokedReason`, `ocspResponse` (`sa/db/01-boulder_sa.sql:37-53`). A true append-only `revokedCertificates` table exists for CRL generation (lines 220-230).
2. **Rendered artifact**: the cert *is* the artifact, produced once and never regenerated. `docs/ISSUANCE-CYCLE.md:9-19`: "Sign, log, and store final certificate... we have a record of what we planned to sign." `ca/ca.go:497` even lint-checks that the to-be-signed cert equals the final leaf cert byte-for-byte.
3. **Revocation**: status flag + reason code + CRL (OCSP has been retired — no responder code exists). Reason codes gated by actor role (`revocation/reasons.go:69-94`). CRLs flow to an S3-compatible object store (`docs/CRLS.md:3-16`); relying parties fetch the CRL, they never call Boulder live.
4. **Signing key**: in a separate process, reachable only via gRPC from the Registration Authority — `README.md:35-42`: "This component model lets us separate the function of the CA by security context." HSM signing via PKCS#11 (`ca/ca.go:18,103-105`); offline root ceremonies use a dedicated `cmd/ceremony` tool.
5. **Storage**: SQL for DER+metadata, object store for CRLs. Identifier is a 136-bit CSPRNG serial (`ca/ca.go:476-489`), not a content hash, not sequential. No backup/DR doc found anywhere in the repo.

### 2. `smallstep/certificates` (step-ca, 8,858★, pushed today)

1. **System of record**: mutable row keyed by serial — `db.Set(certsTable, serial, crt.Raw)` (`db/db.go:323-328`), metadata in a second table, revocation in a third (`revokedCertsTable`), not a status column on the cert row.
2. **Rendered artifact**: cert bytes produced once via a pluggable CAS abstraction, stored verbatim; no re-rendering.
3. **Revocation**: `Revoke()` writes a `RevokedCertificateInfo` (`db.go:216-230`); presence-lookup via `IsRevoked` (`db.go:173`). Self-admitted gap: `// TODO: Add CRL and OCSP support.` (`api/revoke.go:56`) — no OCSP responder exists; the design leans on short-lived certs instead of real-time revocation checking.
4. **Signing key**: pluggable CAS (`cas/apiv1/`) with real backends on disk — in-process `SoftCAS` (can itself be PKCS#11/HSM/cloud-KMS backed), `CloudCAS`/`VaultCAS` (external key custody), and `StepCAS`, which literally proxies signing to a *separate* step-ca instance (`cas/stepcas/stepcas.go:21-23`) — the API-facing process can hold no key at all.
5. **Storage**: embedded BadgerDB by default, MySQL/Postgres/BoltDB via an external `nosql` library; a dedicated `scripts/badger-migration` tool exists, implying DB migration/loss is a recognized operational concern. Key is the serial number string.

### 3. `sigstore/fulcio` (880★, pushed 2 days ago — backs Sigstore/cosign, widely used for software-supply-chain signing)

1. **System of record**: none, by design — the `CertificateAuthority` interface has only `CreateCertificate`/`TrustBundle`/`Close` (`pkg/ca/ca.go:27-31`), no Get/List/Store. The actual record of issuance is a separate transparency log (Rekor), not Fulcio's own storage.
2. **Rendered artifact**: 10-minute-lifetime cert built fresh per request (`pkg/ca/common.go:32-42`).
3. **Revocation**: explicitly absent by design — `docs/security-model.md:20,37`: "Fulcio is designed to avoid the need for revocation of certificates... by issuing short-lived certificates." Verifiers check the validity window plus Rekor inclusion time instead.
4. **Signing key**: production paths use KMS (AWS/Azure/GCP/HashiVault) or HSM (`pkg/ca/kmsca/`, `pkg/ca/pkcs11ca/`); an in-memory `EphemeralCA` exists but is explicitly documented test-only.
5. **Storage**: no database in the repo at all — durability is delegated entirely to the separate Rekor project.

## B. Verifiable-credential / badge frameworks

### 4. `openwallet-foundation/acapy` (formerly `hyperledger/aries-cloudagent-python`, 492★, pushed 2026-09-10)

1. **System of record**: mutable status-column row (`V20CredExRecord.state`, values including `STATE_ISSUED`/`STATE_CREDENTIAL_REVOKED`, `cred_ex_record.py:24-52`) tracking the exchange, wrapping a `VCRecord` that stores the full signed JSON-LD credential blob verbatim (`vc_holder/vc_record.py:15,32`).
2. **Rendered artifact**: no PDF/HTML rendering anywhere — issuer/verifier machinery only. Versioning travels with the object itself (`@context`/`type` arrays inside the stored JSON, `vc_record.py:96-109`), so an old credential stays self-describing without depending on verifier code version.
3. **Revocation**: AnonCreds revocation registries + tails files (`anoncreds/revocation/revocation.py:262-263,1327-1338`); verifier checks a timestamp against the registry's non-revocation interval (`anoncreds/verifier.py:44-49,184`). No W3C StatusList2021/BitstringStatusList support found (zero grep hits).
4. **Signing key**: in-process by default — `AskarWallet` holds keys in the same store the admin API opens directly (`wallet/askar.py:34`). External KMS/HSM signing is documented as an opt-in plugin interface only (`docs/features/JsonLdCredentials.md:229`), not the default path.
5. **Storage**: SQLite or Postgres via Askar (`askar/store.py:28`); identifiers are content-derived DIDs (`did:key:zUC71...`), not sequential IDs. No backup/durability guidance found in code — only deployment config docs.

### 5. Blockcerts: `blockchain-certificates/cert-issuer` (428★, active, last commit 2026-04-13) and `cert-verifier` (45★, **last commit 2020-06-05 — stale, ~6 years, rejected as weak evidence**; its revocation logic only branches on protocol V2, never V3, suggesting verification logic moved to `cert-verifier-js`, not inspected)

1. **System of record**: a signed JSON-LD credential with a Merkle-root blockchain anchor, not a DB row — `merkle_tree_generator.py:43-45` builds the tree; the anchor transaction is written into `certificate_json['proof']` (`proof_handler.py:24-27`).
2. **Rendered artifact**: no baking/PDF code anywhere (zero grep hits); JSON is the sole source of truth. V3 credentials instead carry a `displayHtml` field for human rendering, kept separate from the verifiable content. Context migration is explicit (`proof_handler.py:45-50`).
3. **Revocation**: issuer-hosted list fetched by the verifier at check time — `connectors.py:213-217` fetches `revocationList` from the issuer's own URL; `checks.py:151-160` does membership check. Only wired for the older protocol version.
4. **Signing key**: loaded in-process from a plaintext file expected on a USB stick, with an offline-signing ritual — `config.py:40-42`, `signer.py:52-74` blocks until "internet off and USB plugged in." No HSM support.
5. **Storage**: local filesystem directories (`config.py:43-48`); identifier is a human/sequential `uid` used as the filename — the actual content hash lives only inside the proof, not as the storage key. No documentation found on key loss/backup consequences (a lost issuing key means no way to revoke or reissue against that anchor).

### 6. `edubadges/edubadges-server` (Badgr's real-world successor — `concentricsky/badgr-server`, the original target, **no longer resolves on GitHub, presumably private/deleted post-Instructure acquisition; rejected**. edubadges is SURF's Dutch national production deployment, forked from the same codebase, 50★, pushed today)

1. **System of record**: mutable `BadgeInstance` row — `revoked = BooleanField(default=False)`, `revocation_reason` (`issuer/models.py:1048-1069`). The credential JSON is generated on read via `get_json()`, not stored as one static blob.
2. **Rendered artifact**: baked-PNG support was added then **removed** (migrations `0041_badgeinstancebakedimage.py` → `0120_delete_badgeinstancebakedimage.py`); the JSON assertion is now the sole record. Version handled by `get_json(obi_version=...)` re-rendering under either OBI 1.1 or 2.0 context on demand.
3. **Revocation**: `revoke()` sets `revoked=True`, deletes the badge image, emails the recipient (`models.py:1202`); reads short-circuit to a stub `{'revoked': True, ...}` payload instead of full content (`models.py:1319-1331`).
4. **Signing key**: for OB2.0 "signed" badges and OB3.0/VC issuance alike, key generation/signing is delegated to a **separate external microservice** — Django only stores an encrypted key blob returned by it (`signing/tsob.py:9-19`; `ob3/api.py:27-38` explicitly documents this as a thin proxy to a separate `ec-issuer`/`ssi-agent` service).
5. **Storage**: local filesystem (`mainsite/settings.py:264-265`); `django-storages` is a listed dependency but no active cloud backend config was found. Identifier is a URL-safe base64 UUID4, not a content hash. No backup/durability comments found.

## C. E-signature / document-signing platforms

### 7. `documenso/documenso` (14,980★, updated today; hosted SaaS + self-hosters; Next.js/Prisma/Postgres — structurally closest to aula's own stack)

1. **System of record**: mutable `Envelope.status` enum (`DRAFT/PENDING/COMPLETED/REJECTED/CANCELLED`, `schema.prisma:381-448`) **plus** an append-only `DocumentAuditLog` (no `updatedAt` field — write-once, `schema.prisma:517-534`).
2. **Rendered artifact**: `DocumentData` keeps both current and immutable `initialData`; resealing re-runs the whole signing pipeline from `initialData` and writes a **new** row, repointing the envelope to it (`seal-document.handler.ts:132-142,292-301`) — the old blob is orphaned, not hash-pinned, no guarantee it still verifies.
3. **Revocation**: a COMPLETED document **cannot be cancelled at all** (`cancel-document.ts:71-75`); completed docs get a soft-delete timestamp instead of a hard delete (`delete-document.ts:145-192`). Public verification only matches `status: COMPLETED`; on any other status it silently redirects home with no "revoked" message (`share.$slug.tsx:56-58`).
4. **Signing key**: local `.p12` file or Google Cloud HSM; the local transport reads the key straight off the **app server's own filesystem/env vars**, never the DB (`packages/signing/transports/local.ts:6-19`).
5. **Storage**: S3 key is a random ID (`alphaid(12)`), not a content hash (`s3-provider.ts:47`). No backup/durability docs in-repo.

### 8. `OpenSignLabs/OpenSign` (6,983★, updated today; Parse Server/MongoDB)

1. **System of record**: boolean flags directly on the document row (`IsCompleted`, `IsDeclined`), no enum; audit trail is an array embedded on the same document, not a separate collection.
2. **Rendered artifact**: certificate PDF generated once, gated by `IsCompleted && !CertificateUrl` — if a `CertificateUrl` already exists it returns empty rather than regenerating (`generateCertificatebydocId.js:59,95`).
3. **Revocation**: a completed document **cannot be declined** either — the decline query explicitly filters out completed docs (`declinedocument.js:58-59,66-68`).
4. **Signing key**: production key is `PFX_BASE64`/`PASS_PHRASE` env vars read on the same app server (`.env.example:55,58`; `generateCertificatebydocId.js:48,68`) — no KMS/HSM.
5. **Storage**: S3 (DigitalOcean Spaces) or local filesystem, chosen by an env flag (`index.js:23-58,160`); files keyed by filename, not content hash.

**Notable pattern across both e-sign tools**: neither actually supports revoking a *completed* document — once signed, the record is effectively permanent. This is a real gap against aula's explicit requirement that certificates be revocable.

## D. LMS certificate modules (the category aula is directly replacing)

### 9. Moodle `mod_customcert` (bundled in `moodle/moodle`, 7,396★; plugin repo `mdjnelson/moodle-mod_customcert`, 111★)

1. **System of record**: a mutable row with **no status column at all** — `customcert_issues`: `id, userid, customcertid, code, emailed, studentemailed, timecreated` (`db/install.xml:47-67`). Existence of the row is the only signal of validity; verification is a raw existence query (`verify_certificate.php:125`).
2. **Rendered artifact**: regenerated fresh on every view/download from the template's *current* elements (`classes/service/pdf_generation_service.php:86-127`); nothing is cached. `customcertid` → `templateid` is a **live foreign key** (`install.xml:11,31`) — editing a template silently changes how every already-issued certificate renders, past and future. No per-issue template snapshot exists.
3. **Revocation**: hard delete, not a status flip — `issue_repository.php:122`, `$DB->delete_records('customcert_issues', ['id' => $id])`. An event fires but no tombstone/audit row survives.
4. **Pre-allocation**: not supported — issuance only happens once completion is confirmed (`certificate_issue_service.php:72-98`), driven by a scheduled task. No "pending"/pre-eligibility state exists.
5. **Storage**: no PDF bytes stored anywhere (always regenerated). Verification code is a human-readable random string in `code CHAR(40)` with only a **non-unique index** (`install.xml:52,65`) — uniqueness is enforced app-side by a retry loop, not the database.

### 10. Open edX (`openedx/edx-platform`, 8,185★; `openedx/credentials`, 25★)

1. **System of record**: mutable row + status enum, mirrored into an append-only history table — `GeneratedCertificate.status` (default `'unavailable'`, `models.py:169-259`), unique per `(user, course_id)`, with `HistoricalRecords()` auto-mirroring every change. Statuses: `downloadable, generating, error, unavailable, invalidated, notpassing, requesting` (`data.py:43-57`).
2. **Rendered artifact**: on-demand HTML render from a live-matched template — `CertificateTemplate.template` is raw HTML text matched by org/course/mode/language + `is_active` at render time, **no per-certificate version pin** (deactivating/editing a template changes rendering for old certs too, `models.py:1136-1159`). Legacy PDF fields are explicitly deprecated in-code, citing an internal ADR (`models.py:241-245`).
3. **Revocation**: layered — a status flip (`invalidate()`) *plus* a dedicated soft-delete audit table, `CertificateInvalidation` (FK to the cert, `invalidated_by`, `notes`, `active` boolean, `deactivate()` flips the flag rather than deleting, `models.py:626-704`). The separate `credentials` service models revocation even more simply: `UserCredential.STATUSES_CHOICES = (AWARDED, REVOKED)`, `revoke()` just flips status (`credentials/apps/credentials/models.py:159-196`).
4. **Pre-allocation**: partial — `generating`/`requesting` represent an async-render window, but only *after* the pass signal, not before eligibility. No evidence of allocating an identifier ahead of the pass/fail determination (aula's actual print-then-sign requirement isn't modeled here).
5. **Storage**: no PDF blob in the DB; identifiers are real DB-enforced UUIDs (`verify_uuid`, `models.py:231`; `credentials` app's `UserCredential.uuid`, unique, `models.py:185`) — unlike Moodle's app-level, non-unique-indexed code.

## E. Infrastructure-scale certificate issuance

### 11. `cert-manager/cert-manager` (dominant Kubernetes-native X.509 lifecycle manager)

1. **System of record**: declarative `Certificate`/`CertificateRequest` CRDs, but the issued cert bytes live only in a `Secret`, not the CR — `CertificateStatus` (`types_certificate.go:649-718`) has no bytes field at all, only conditions/dates/revision. The one-shot `CertificateRequest.Status.Certificate []byte` holds the PEM and is explicitly documented as "cannot be re-used."
2. **Rendered artifact**: no templating — the Secret's PEM is the literal signed output copied from the one-shot request. Re-issuance creates a brand-new revision-tracked request and overwrites the Secret.
3. **Revocation**: no first-class object — delegated entirely to the Issuer backend (ACME/Vault/Venafi); cert-manager itself maintains no CRL/OCSP.
4. **Signing key**: never in the controller process except for trivial self-signed issuers — real issuers are Secret-stored keypairs or fully external (Vault/ACME/Venafi).
5. **Storage**: Kubernetes etcd via Secret objects. No backup/durability guidance found in this codebase.

### 12. HashiCorp Vault PKI secrets engine (`hashicorp/vault`, `builtin/logical/pki`)

1. **System of record**: mutable storage entries, not a log — certs at `certs/<serial>`, revocations at `revoked/<serial>` (`RevocationInfo` struct, `revocation/revoke.go:37-42`), issuers/keys similarly mutable (`issuing/issuers.go:123-142`, `issuing/keys.go:29-34`).
2. **Rendered artifact**: cert bytes are canonical, no template layer; issuance also creates a Vault *lease* that auto-revokes on expiry.
3. **Revocation**: writes to `revoked/` and triggers CRL rebuild (`secret_certs.go:46-77`); relying parties check the CRL or query OCSP (`path_ocsp.go:163`).
4. **Signing key**: in the same barrier-encrypted storage backend as everything else in OSS Vault; HSM/KMS offload ("managed keys") is gated to Enterprise only (`managed_key_util_oss.go:17`, explicit build-tag error).
5. **Storage**: keyed by serial/UUID inside Vault's storage backend. No code-level backup/DR guidance found (may exist only in separate ops docs, not verified here).

## Systems rejected

- `concentricsky/badgr-server` — repo no longer resolves on GitHub (likely made private after the Instructure/Canvas Credentials acquisition); substituted with its real-world fork, `edubadges-server`.
- `blockchain-certificates/cert-verifier` — 6 years without a commit, revocation logic never updated past protocol V2; treated as weak evidence and flagged rather than relied on.
- No repo was rejected purely for low stars — all 12 reported above showed either massive real deployment (Let's Encrypt, cert-manager, Vault, Moodle, Open edX) or concrete production use by a named organization (Documenso/OpenSign hosted SaaS, edubadges/SURF, ACA-Py/OpenWallet Foundation members, Boulder/step-ca/Fulcio backing real CAs).

## The structural difference: "document" vs "credential" systems

Across all 12 codebases, the split is not about domain (diplomas vs. TLS certs) — it's about **where the verifier's trust is rooted**, and that decision cascades into every other design choice:

**Document systems** (Moodle, Open edX, Documenso, OpenSign) store a mutable database row and render a view of it on demand from a template fetched *live by foreign key*. Verification means asking the issuer's own server "does this row exist, what's its current status" — trust is rooted in the issuer's live system, not in the artifact. This has a direct, observed consequence: none of the four document systems above version their templates per issuance (Moodle's `templateid` and Open edX's org/course/mode/language template match are both live lookups), so editing a template retroactively changes how *already-issued* documents render. Revocation is just a status column or delete, checked live, and two of the four (Documenso, OpenSign) don't even support revoking a completed document at all.

**Credential systems** (Boulder, step-ca, Fulcio, ACA-Py, Blockcerts, cert-manager, Vault) treat the signed artifact itself — X.509 DER, a JSON-LD VC, a PEM — as the portable, self-contained record, fixed at issuance and (mostly) never regenerated. The schema/context version travels *inside* the object, so an old artifact stays interpretable without depending on current issuer state. Verification can happen without calling the issuer's live server at all, given the issuer's public key plus a revocation feed (CRL/OCSP/status registry) checked as an explicitly separate step. This is why every credential system surveyed puts real structural weight on separating the signing key from the web-facing process — Boulder's gRPC-only CA process, step-ca's proxying CAS backend, Fulcio's KMS/HSM requirement — because the artifact's trustworthiness depends entirely on that key never touching the same process an attacker might compromise via the web app. Document systems (Documenso, OpenSign) don't bother: their signing key sits in the app server's own filesystem/env vars, because their trust model never asked the artifact to stand on its own.

## Recommendation for aula

**Build aula as a document system, explicitly not a credential system** — a mutable row with a status enum, verified live at `/verificar/<code>` against CICAT's own database, not a self-contained cryptographically-signed artifact.

Why the evidence supports this: the domain context already commits to live-server verification ("Third parties verify a certificate at /verificar/<code>, from a QR"), which is exactly the document-system trust model — a verifier calling back to the issuer's live database. Cryptographic self-containment (the entire reason PKI/VC systems separate signing keys, version schemas inside the artifact, and build CRL/status-list infrastructure) exists to let a verifier trust an artifact *without* calling the issuer — because Let's Encrypt-issued certs must validate in millions of independent browsers, and Blockcerts credentials must survive independent of any live issuer server. CICAT has one issuer, thousands of certificates a year, and a verifier that already talks to CICAT's own server every time. None of the infrastructure a credential system pays for — HSM/KMS custody, revocation-registry publishing, portable signature-scheme versioning — buys anything under that model.

Two specific things to take from the credential side despite that choice, because they're gaps observed in *every* document system surveyed and directly relevant to aula's own stated requirements:

1. **Pin the template per issuance**, not by live foreign key. Every document system surveyed (Moodle, Open edX) uses a live FK to the current template, so editing a template retroactively changes historical certificates — the opposite of aula's already-stated determinism requirement (pinned typst timestamp, `--ignore-system-fonts`). Store a template version identifier (or hash of the typst source) alongside the record at issuance time, matching the pattern PKI systems use of fixing the artifact's schema version at creation.
2. **Revoke via a status flag with a separate audit trail, not a hard delete.** Moodle's hard-delete-with-no-status-column loses the fact a certificate ever existed; Open edX's `CertificateInvalidation` table (FK, `invalidated_by`, `notes`, `active` boolean) is the better-evidenced pattern for a system that must support pre-allocated, printed-before-passing certificates and later revocation with an audit record of why.

What this costs: verification becomes unavailable if CICAT's server or database is unreachable — there is no way for a third party to check a certificate offline or independent of CICAT staying online, which is precisely the failure mode PKI/VC architectures are built to avoid. For a single institute with thousands of certificates a year and a verification flow that already assumes a live callback, that cost is one the domain has already accepted by design; building the credential-system alternative (detached signatures, key custody infrastructure, a published revocation registry) would be paying PKI's price to solve a many-independent-verifiers problem CICAT doesn't have.
