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

## Open, confirmed by gate B on the tenancy branch, present on master before it

- [ ] `apps/backend/src/adapters/whatsapp/index.ts:126` - the adapters return
  `null` on an HTTP error, a network error, or a timeout, and the service records
  status `failed` and resolves. Command execution then persists the phase and the
  inbox marks the message processed, so a customer's reply is lost with no retry.
  Needs shaping first: what a retry means for a reply that may have been sent.

## Open, found after the tenancy landing

- [ ] `apps/backend/src/domains/reports/index.ts:40` - the daily report cuts the
  day at the server's local time, while the dashboard shows America/Lima. On a UTC
  server a Lima day is reported five hours off.

- [ ] `/api/reports/daily` with an invalid `date` throws a `RangeError` at the
  `toISOString()` that builds the filename and returns 500.

- [ ] `apps/backend/src/domains/analytics/index.ts:43` - a date-only end such as
  `2026-03-10` is read as UTC midnight, so the funnel excludes that day. Nothing in
  the frontend calls `/api/analytics/funnel` yet.

- [ ] `packages/types/src/index.ts:129` types `Conversation.last_activity_at` as
  `string`, but the column is INTEGER milliseconds and `routes/conversations.ts:52`
  returns it raw.

- [ ] `MessageType` in `packages/types/src/whatsapp.ts` is wider than
  `messages.type`, which `schema.sql:221` restricts to `text` and `image`.
  Document, audio, video and `unknown` would throw at the CHECK if a caller stored
  one. Unreachable today: the webhook returns before logging a non-text message.
  Give the parser its own type and keep `MessageType` for what is stored.

- [ ] `packages/core/src/validation/affirmation.ts:5` and `:64` - CodeQL
  `js/polynomial-redos` (high, alerts #5 and #6, open since 2026-01-19).
  `isAffirmative` and `isNegative` strip trailing punctuation with
  `/[¡!¿?.,:;]+$/`, which backtracks quadratically on a long run of punctuation.
  Measured: 4000 `!` plus one letter takes 11.6 ms, so the cost is bounded, but
  the webhook accepts unsigned payloads (first entry above). One shared linear
  helper that scans from the end removes both alerts and the duplicated line.

- [ ] Comment debt on `master` from the tenancy landing: `cap check` reports 119
  added comment blocks over six lines and 8 comments that narrate history
  (`no longer`, `used to`) in `736c2ee~1..2cd7ff3`. Run `cap cleanup` on a task
  branch and review the removals; it has stripped genuine comments before.
