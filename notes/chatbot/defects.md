# chatbot: known defects

Defects in the chatbot project itself. A defect in Captain belongs in
`paper-cuts.md`; this file is the other side of that boundary.

Each entry names the file, what is wrong, and the failure it causes. The next
task on this project should read this before starting.

## Open, found while landing vendeya-tenant-foundation

- [ ] `apps/backend/src/routes/webhook.ts:252` - the POST handler never verifies
  Meta's `X-Hub-Signature-256` (no `hub-signature` or `hmac` anywhere in the
  file). A forged payload that names a known `phone_number_id` is accepted as if
  Meta sent it. Present before the tenancy work, so it is not a regression.

- [ ] `apps/backend/src/routes/admin/users.ts:80` - creating a user checks that
  the password is present and nothing else, so a tenant admin can create an
  account with a one-character password. The reset route at `:217` requires 6.
  `MIN_PASSWORD_LENGTH` in `domains/accounts/index.ts` requires 12 and only the
  `bun run account` command applies it.

- [ ] `apps/backend/src/db/schema.sql:434` - `audit_log.user_id` is NOT NULL, so
  `bun run account create` and `promote` cannot record who created or promoted
  an account. Granting cross-tenant powers leaves no record outside the
  operator's terminal.

- [ ] `apps/backend/src/db/query.ts:11` - `getOne` is typed `T | undefined`, but
  `bun:sqlite` returns `null` when no row matches. A `=== undefined` check on its
  result is always false. It broke the first draft of the account module and a
  test caught it; no other live instance was found.

- [ ] `.github/workflows/codeql.yml` is the only workflow. Nothing in CI runs the
  backend tests, the typecheck, or the format check on a pull request, so the
  local suite is the only gate.

- [ ] Tests that build a file-backed temporary database run `initializeDatabase`
  with a `fsync` per statement. On a slow disk `seeding.test.ts` "keeps two
  tenants whose ids share a prefix apart" exceeds the default 5s (6579ms here).
  `PRAGMA synchronous = OFF` on those databases took `accounts.test.ts` from 55s
  to 7.5s.
