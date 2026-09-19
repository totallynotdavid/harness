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

## Open, confirmed by gate B on the tenancy branch, present on master before it

Gate B (luna) failed the branch on these. Each matches `master` line for line, so
they are fixed in a follow-up pull request, not in the tenancy one.

- [ ] `apps/backend/src/adapters/whatsapp/index.ts:126` - the adapters return
  `null` on an HTTP error, a network error, or a timeout, and the service records
  status `failed` and resolves. Command execution then persists the phase and the
  inbox marks the message processed, so a customer's reply is lost with no retry.

- [ ] `apps/backend/src/domains/analytics/index.ts:47` - `getFunnelStats` binds
  ISO strings to `created_at BETWEEN ? AND ?`, but the column is INTEGER
  milliseconds. SQLite orders every integer before every string, so the range
  matches nothing. Reproduced: one in-range row returns 0 with ISO strings and 1
  with millisecond bounds. The funnel reports zero for real events.

- [ ] `apps/backend/src/domains/reports/index.ts:40` - `generateDailyReport` binds
  ISO strings to `last_activity_at`, an INTEGER millisecond column. Conversations
  in range are missing from the daily report.

- [ ] `apps/backend/src/routes/admin/users.ts:80` - see the password entry above;
  gate B confirmed it. Create needs a minimum and reset should match the 12 the
  account command enforces.

- [ ] `apps/backend/src/adapters/whatsapp/parsers/cloud-api-parser.ts:20` - an
  unknown message type (reaction, location, sticker) falls through to `text` with
  an empty body, which bypasses the webhook's non-text guard, so it is queued and
  processed as an empty customer message.

- [ ] `apps/backend/package.json:12` - `test` runs `bun test --env-file=../../.env`
  without `NODE_ENV=test`. With a development `.env` the suite selects the dev
  adapter while tests mock Cloud API response shapes, and gate B saw the default
  command time out or report `send_failed`. Setting `NODE_ENV=test` passed the same
  suites there. A full run here passed 486 of 487 without it.

## Open, found after the tenancy landing

- [ ] `packages/core/src/validation/affirmation.ts:5` and `:64` - CodeQL
  `js/polynomial-redos` (high, alerts #5 and #6, open since 2026-01-19).
  `isAffirmative` and `isNegative` strip trailing punctuation with
  `/[¡!¿?.,:;]+$/`, which backtracks quadratically on a long run of punctuation.
  Measured: 4000 `!` plus one letter takes 11.6 ms, so the cost is bounded, but
  the webhook accepts unsigned payloads (first entry above). One shared linear
  helper that scans from the end removes both alerts and the duplicated line.

- [ ] Comment debt on `master` from the tenancy landing: `cap check` reports 119
  added comment blocks over six lines and 8 comments that narrate history
  (`no longer`, `used to`) in `736c2ee~1..2cd7ff3`. Run `cap cleanup` after
  `vendeya-fix-preexisting` lands, since both touch the same files.

- [ ] The 33 commits from `736c2ee` to `2cd7ff3` are unsigned on GitHub. Each was
  signed locally; GitHub's rebase merge re-created them. Every earlier commit on
  `master` is verified. See paper cut #6.
