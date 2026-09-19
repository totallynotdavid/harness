# Gate B: vendeya-fix-preexisting

luna reviewed the changes since 2cd7ff36573a, with HEAD at 2cd7ff36573a (fingerprint cf20a6685a7c). Verdict: PASS.

## Findings

- [minor, confirmed] `apps/backend/tests/setup.ts:32` Setting NODE_ENV to test selects CloudApiAdapter because the adapter selector uses DevAdapter only for development; tests that rely on the dev adapter can instead exercise production Cloud API behavior or make unintended network calls. (finding bdbc24a9)
- [minor, confirmed] `packages/types/src/whatsapp.ts:7` Adding unknown to the shared MessageType allows MessageStore.log to receive a value rejected by the messages.type SQLite CHECK constraint, causing logging to throw instead of persisting the message. (finding 71ca6b07)

## Checked

- `apps/backend/src/adapters/whatsapp/parsers/cloud-api-parser.ts`: Unknown Cloud API types map to unknown and known types remain unchanged; webhook tests pass.
- `apps/backend/src/conversation/store.ts`: Conversation updates and resets write epoch-millisecond activity timestamps.
- `apps/backend/src/db/init.ts`: Timestamp backfill runs for fresh and migrated databases.
- `apps/backend/src/db/migrations.ts`: ISO and SQLite text timestamps convert correctly and idempotently.
- `apps/backend/src/domains/accounts/index.ts`: The shared password minimum remains exported and account tests pass.
- `apps/backend/src/domains/analytics/index.ts`: Funnel range queries use millisecond bounds and date tests pass.
- `apps/backend/src/domains/conversations/write.ts`: Manual takeover writes a numeric activity timestamp.
- `apps/backend/src/domains/reports/index.ts`: Daily report range queries use millisecond bounds.
- `apps/backend/src/routes/admin/users.ts`: Create and reset routes reject short and non-string passwords and accept the exact minimum.
- `apps/backend/tests/activity-timestamp-backfill.test.ts`: All six backfill tests pass.
- `apps/backend/tests/date-bounds.test.ts`: All date-bound and timestamp-write tests pass.
- `apps/backend/tests/migration.test.ts`: Migration and timestamp conversion tests pass.
- `apps/backend/tests/password-minimum.test.ts`: All password minimum route tests pass.
- `apps/backend/tests/setup.ts`: Temporary database and storage paths are configured; adapter-selection mismatch is reported above.
- `apps/backend/tests/test-environment.test.ts`: All four NODE_ENV propagation tests pass.
- `apps/backend/tests/unknown-message-types.test.ts`: Unknown-message webhook behavior tests pass.
- `apps/frontend/src/lib/components/admin/user-form.svelte`: Client-side minimum validation and helper text type-check successfully.
- `apps/frontend/src/lib/utils/password.ts`: Shared Spanish short-password message uses the exported minimum.
- `apps/frontend/src/routes/dashboard/admin/users/[userId]/+page.svelte`: Password reset prompt and client-side validation type-check successfully.
- `apps/frontend/src/routes/dashboard/admin/users/create/+page.svelte`: User creation validation and minimum-length text type-check successfully.
- `packages/types/src/accounts.ts`: The shared minimum constant is defined as 12.
- `packages/types/src/index.ts`: The shared password constant is exported and TypeScript compilation passes.
- `packages/types/src/whatsapp.ts`: The expanded union compiles; its persistence mismatch is reported above.

## Reviewer's report

Findings:

- `apps/backend/tests/setup.ts:32`: `NODE_ENV=test` selects `CloudApiAdapter`, not a test adapter; the selector only uses `DevAdapter` for `development`. Tests relying on the dev adapter may call production-style Cloud API behavior.
- `packages/types/src/whatsapp.ts:7`: `unknown` is allowed by the shared persisted `MessageType`, but `messages.type` only permits `text` and `image`; logging `"unknown"` through `MessageStore.log` throws a SQLite CHECK-constraint error.

Targeted tests passed: 90 tests; backend and package TypeScript checks passed; frontend check reported 0 errors and 0 warnings. The full suite had one 5-second timeout, while the isolated test passed with a 15-second timeout:

```text
(fail) seeding a catalog > keeps two tenants whose ids share a prefix apart [6664.05ms]
  ^ this test timed out after 5000ms.
```

No files were edited.
