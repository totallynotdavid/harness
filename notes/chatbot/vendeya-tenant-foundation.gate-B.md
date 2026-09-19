# Gate B: vendeya-tenant-foundation

luna reviewed the changes since eb0d07f83663, with HEAD at f241ae53f6ac (fingerprint 95e488861749). Verdict: FAIL.

## Findings

- [major, confirmed] `apps/backend/src/adapters/whatsapp/index.ts:126` CloudApiAdapter and DevAdapter return null on HTTP errors, network errors, and timeouts, but WhatsAppService only logs status failed and resolves. Command execution then persists phases/events and the inbox/held workers mark messages processed, so a customer reply can be lost permanently without retry. (finding b56585f8)
- [major, confirmed] `apps/backend/src/domains/analytics/index.ts:47` analytics_events.created_at is an INTEGER millisecond timestamp, while getFunnelStats binds ISO date strings to BETWEEN. A direct SQLite reproduction with an in-range integer event returns zero rows, so the funnel endpoint reports zero counts for real events. (finding 096daa43)
- [major, confirmed] `apps/backend/src/domains/reports/index.ts:40` generateDailyReport binds ISO strings to last_activity_at even though the schema stores that field as INTEGER milliseconds and some writes use numeric/current timestamps. Valid conversations can therefore be omitted from daily XLSX reports. (finding e7c75712)
- [major, confirmed] `apps/backend/src/routes/admin/users.ts:84` The HTTP admin create route only checks that password is truthy, and the reset route accepts six characters, bypassing MIN_PASSWORD_LENGTH=12 used by account creation and documented for operators; web admins can create or set weak passwords. (finding a5366fb8)
- [minor, confirmed] `apps/backend/src/adapters/whatsapp/parsers/cloud-api-parser.ts:20` Unknown Cloud API message types are mapped to text with an empty body. The webhook's non-text guard is therefore bypassed, allowing reactions, locations, stickers, or future types to be queued and processed as empty customer messages. (finding b34d2179)
- [major, confirmed] `apps/backend/src/conversation/locks.ts` The supplied review brief does not state the full states, transition owners, and timing for the changed lock, queue, session, and idempotency state. code.md requires that invariant statement before such changes and explicitly defines its absence as a defect. (finding 9b26b933)
- [minor, confirmed] `apps/backend/package.json:12` The default test script loads the development .env without setting NODE_ENV=test, selecting DevAdapter while changed tests mock Cloud API response shapes. In this worktree the default command timed out or reported send_failed; the same targeted suites passed when NODE_ENV=test was set. (finding 5c5daa35)

## Checked

- `.env.example`: Verified documented storage, encryption, WhatsApp, and token-generation settings.
- `.env.production.example`: Verified production paths and required secret documentation.
- `.gitignore`: Verified database, storage, private assets, environment, and generated files are excluded.
- `apps/backend/bunfig.toml`: Verified backend test preload points at the throwaway test setup.
- `apps/backend/src/adapters/storage/images.ts`: Verified catalog image storage behavior through seed-image and catalog-image tests.
- `apps/backend/src/adapters/storage/private-files.ts`: Verified private storage path handling and access guards through private-asset and path-guard tests.
- `apps/backend/src/adapters/whatsapp/cloud-api.ts`: Verified Cloud API payloads, credentials, response parsing, and failure paths by source inspection and targeted tests.
- `apps/backend/src/adapters/whatsapp/dev-adapter.ts`: Verified active, pending, and disabled development-channel behavior in suspended/disabled-channel tests.
- `apps/backend/src/adapters/whatsapp/message-store.ts`: Verified tenant/channel-scoped message history and quoted-message lookups through conversation and webhook tests.
- `apps/backend/src/adapters/whatsapp/parsers/index.ts`: Verified parser exports compile and are consumed by the webhook route.
- `apps/backend/src/adapters/whatsapp/types.ts`: Verified adapter interfaces and message types compile.
- `apps/backend/src/bootstrap/event-bus-setup.ts`: Verified event-bus setup through backend compilation and recovery/notification tests.
- `apps/backend/src/cli/account.ts`: Account creation/promotion behavior passed account CLI tests.
- `apps/backend/src/cli/read-password.ts`: Hidden prompt, stdin, mismatch, and multiline-password behavior passed CLI tests.
- `apps/backend/src/conversation/aggregator-worker.ts`: Queue grouping, lock handling, retry, and disabled-channel behavior passed targeted tests.
- `apps/backend/src/conversation/enrichment/handler-interface.ts`: Verified enrichment handler contracts compile.
- `apps/backend/src/conversation/enrichment/handlers/check-eligibility-handler.ts`: Eligibility enrichment behavior passed recovery and handler tests.
- `apps/backend/src/conversation/enrichment/index.ts`: Verified enrichment registration and loop integration compile and pass handler tests.
- `apps/backend/src/conversation/handler/command-executor.ts`: Interrupted-transition and lock tests passed under NODE_ENV=test; state persistence ordering was inspected.
- `apps/backend/src/conversation/handler/enrichment-loop.ts`: Verified enrichment retry/limit paths through handler and recovery tests.
- `apps/backend/src/conversation/handler/orchestrator.ts`: Verified orchestration, tenant references, and event propagation through interrupted-transition and recovery tests.
- `apps/backend/src/conversation/held-messages.ts`: Held-message deduplication, claiming, maintenance, and retry tests passed.
- `apps/backend/src/conversation/images.ts`: Verified image command handling and catalog image tests.
- `apps/backend/src/conversation/message-inbox.ts`: Inbox grouping, status transitions, deduplication, and retry tests passed.
- `apps/backend/src/conversation/process-held.ts`: Maintenance and held-message sweep tests passed under NODE_ENV=test.
- `apps/backend/src/conversation/processed-retention.ts`: Retention behavior compiled and database tests passed.
- `apps/backend/src/conversation/store.ts`: Tenant/channel/phone conversation identity isolation passed simulator and HTTP tests.
- `apps/backend/src/db/connection.ts`: Verified shared application connection and test DB selection.
- `apps/backend/src/db/init.ts`: Boot initialization passed boot-safety tests.
- `apps/backend/src/db/migrations.ts`: Migration suite passed 58 tests, including legacy data, credentials, uploads, and sessions.
- `apps/backend/src/db/query.ts`: Tenant predicates and scoped query helpers passed tenant isolation tests.
- `apps/backend/src/db/schema.sql`: Foreign-key and composite-reference tests passed.
- `apps/backend/src/db/seed.ts`: Seeding behavior passed migration, seed, and boot tests.
- `apps/backend/src/db/seeds/bundles.ts`: Bundle seeding passed catalog and migration tests.
- `apps/backend/src/db/seeds/images.ts`: Image installation passed 7 seed-image tests.
- `apps/backend/src/db/seeds/periods.ts`: Period seeding passed targeted seeding and migration tests.
- `apps/backend/src/db/seeds/products.ts`: Product seeding passed catalog and migration tests.
- `apps/backend/src/db/seeds/tenants.ts`: Tenant/channel seeding and ownership passed migration and tenant tests.
- `apps/backend/src/db/seeds/test-data.ts`: Test fixture data compiled and passed database tests.
- `apps/backend/src/db/seeds/users.ts`: User seed behavior passed migration and account tests.
- `apps/backend/src/domains/accounts/index.ts`: Shared 12-character account password policy and account operations passed account tests.
- `apps/backend/src/domains/assets/content-types.ts`: Asset content-type handling passed upload/private-asset tests.
- `apps/backend/src/domains/assets/index.ts`: Tenant asset ownership and deletion behavior passed asset tests.
- `apps/backend/src/domains/catalog/bundles.ts`: Bundle ownership, image replacement, and deletion passed catalog-image tests.
- `apps/backend/src/domains/catalog/ids.ts`: Catalog ID generation compiled and passed catalog tests.
- `apps/backend/src/domains/catalog/periods.ts`: Period ownership/status behavior passed catalog and tenant tests.
- `apps/backend/src/domains/catalog/products.ts`: Product/category/brand scoping passed catalog and tenant tests.
- `apps/backend/src/domains/channels/accounts.ts`: Channel credential, status, tenant ownership, and activation tests passed.
- `apps/backend/src/domains/conversations/assignment.ts`: Assignment and timeout behavior passed tenant HTTP and disabled-channel tests.
- `apps/backend/src/domains/conversations/media.ts`: Conversation media asset handling passed private-assets and upload tests.
- `apps/backend/src/domains/conversations/read.ts`: Conversation reads remained tenant/channel scoped in HTTP and isolation tests.
- `apps/backend/src/domains/conversations/write.ts`: Manual messaging and conversation writes passed tenant HTTP and disabled-channel tests.
- `apps/backend/src/domains/eligibility/fnb.ts`: FNB provider behavior passed recovery/provider tests.
- `apps/backend/src/domains/eligibility/gaso.ts`: GASO/PowerBI provider behavior passed recovery/provider tests.
- `apps/backend/src/domains/eligibility/handlers/check-eligibility-handler.ts`: Eligibility result and outage handling passed mapper/recovery tests.
- `apps/backend/src/domains/eligibility/mapper.ts`: Eligibility mapping passed eligibility-mapper tests.
- `apps/backend/src/domains/eligibility/providers/fnb-provider.ts`: FNB provider error and success paths passed recovery tests.
- `apps/backend/src/domains/eligibility/providers/powerbi-provider.ts`: PowerBI provider error and success paths passed recovery tests.
- `apps/backend/src/domains/eligibility/providers/provider.ts`: Provider interface and error types compiled and passed provider tests.
- `apps/backend/src/domains/eligibility/shared.ts`: Shared eligibility queries passed tenant and recovery tests.
- `apps/backend/src/domains/notifications/__snapshots__/evaluator.test.ts.snap`: Notification evaluator snapshot remained consistent with evaluator tests.
- `apps/backend/src/domains/notifications/config.ts`: Notification configuration passed notification-routing tests.
- `apps/backend/src/domains/notifications/dispatcher.ts`: Notification routing, platform fallback, and failed-delivery recording passed under NODE_ENV=test.
- `apps/backend/src/domains/notifications/resolver.ts`: Recipient resolution and unknown-target handling passed notification tests.
- `apps/backend/src/domains/notifications/service.ts`: Notification service integration compiled and passed routing tests.
- `apps/backend/src/domains/notifications/templates.ts`: Notification content/template tests passed.
- `apps/backend/src/domains/orders/read.ts`: Tenant-scoped order reads, filters, metrics, and conversation lookup passed HTTP tests.
- `apps/backend/src/domains/orders/types.ts`: Order types compiled and passed backend typecheck.
- `apps/backend/src/domains/orders/write.ts`: Tenant-scoped order creation/status updates passed foreign-key and HTTP tests.
- `apps/backend/src/domains/personas/index.ts`: Tenant persona reads and fallback behavior passed simulator tests.
- `apps/backend/src/domains/recovery/handlers/index.ts`: Recovery handler registration compiled and recovery tests passed.
- `apps/backend/src/domains/recovery/handlers/retry-eligibility-handler.ts`: Eligibility recovery passed provider outage tests.
- `apps/backend/src/domains/recovery/processor/conversation-processor.ts`: Recovery conversation processing passed recovery tests.
- `apps/backend/src/domains/recovery/store/recovery-store.ts`: Recovery state storage passed recovery tests.
- `apps/backend/src/domains/settings/system.ts`: Platform/tenant maintenance settings passed HTTP and maintenance tests.
- `apps/backend/src/domains/system/logs.ts`: System log scoping passed tenant HTTP tests.
- `apps/backend/src/domains/tenants/index.ts`: Tenant creation, membership, status, and isolation passed tenant tests.
- `apps/backend/src/index.ts`: Backend startup, route mounting, and boot-safety tests passed.
- `apps/backend/src/intelligence/service.ts`: Intelligence service compiled and passed LLM-related tests.
- `apps/backend/src/intelligence/tracker.ts`: LLM tracking compiled and passed backend tests.
- `apps/backend/src/lib/http.ts`: HTTP parameter/error helpers compiled and passed route tests.
- `apps/backend/src/lib/storage-paths.ts`: Storage root/path guards and seed-image tests passed.
- `apps/backend/src/middleware/auth.ts`: Authentication, role, tenant pinning, and suspension tests passed.
- `apps/backend/src/middleware/error.ts`: Error middleware compiled and passed HTTP tests.
- `apps/backend/src/platform/audit/logger.ts`: Audit writes and tenant attribution passed operations-audit tests under NODE_ENV=test.
- `apps/backend/src/platform/auth/scope.ts`: Scope derivation and tenant predicate behavior passed authorization tests.
- `apps/backend/src/platform/auth/session.ts`: Session creation, validation, expiration, and tenant switching passed authorization tests.
- `apps/backend/src/platform/crypto/secrets.ts`: Secret encryption/decryption and key handling passed migration/channel tests.
- `apps/backend/src/routes/admin.ts`: Admin route composition and authorization passed tenant HTTP tests.
- `apps/backend/src/routes/admin/channels.ts`: Channel administration and activation guards passed tenant HTTP tests.
- `apps/backend/src/routes/admin/operations.ts`: Maintenance sweep authorization and audit routing passed operations tests under NODE_ENV=test.
- `apps/backend/src/routes/admin/system.ts`: System settings/log routes passed authorization tests.
- `apps/backend/src/routes/analytics.ts`: Analytics route scope and parameter forwarding compiled; query timestamp defect is recorded separately.
- `apps/backend/src/routes/assets.ts`: Public/private asset routing and tenant guards passed asset tests.
- `apps/backend/src/routes/auth.ts`: Login/session authorization passed tenant HTTP tests.
- `apps/backend/src/routes/catalog.ts`: Catalog route ownership and validation passed catalog tests.
- `apps/backend/src/routes/conversations.ts`: Conversation listing/detail/action scoping passed tenant HTTP tests.
- `apps/backend/src/routes/orders.ts`: Order route scoping and status behavior passed tenant HTTP tests.
- `apps/backend/src/routes/periods.ts`: Period route ownership and status behavior passed catalog tests.
- `apps/backend/src/routes/simulator.ts`: Simulator replay, per-number identity, and tenant isolation passed simulator tests.
- `apps/backend/src/routes/system-logs.ts`: System log route authorization passed tenant HTTP tests.
- `apps/backend/src/routes/tenants.ts`: Tenant selection/suspension behavior passed authorization tests.
- `apps/backend/src/routes/webhook.ts`: Webhook verification, batch routing, duplicate suppression, maintenance, and tenant isolation passed tests.
- `apps/backend/src/shared/events/async-emitter.ts`: Async event emission compiled and passed backend tests.
- `apps/backend/src/shared/events/types.ts`: Event tenant/channel typing compiled and passed backend typecheck.
- `apps/backend/tests/account-cli.test.ts`: All account CLI scenarios passed.
- `apps/backend/tests/accounts.test.ts`: Account service/password policy scenarios passed.
- `apps/backend/tests/boot-safety.test.ts`: Boot safety tests passed.
- `apps/backend/tests/catalog-images.test.ts`: All catalog image ownership/deletion tests passed.
- `apps/backend/tests/conversation-lock.test.ts`: All lock/late-answer tests passed with NODE_ENV=test.
- `apps/backend/tests/disabled-channel-processing.test.ts`: Disabled/pending channel queue behavior passed.
- `apps/backend/tests/eligibility-mapper.test.ts`: Eligibility mapper tests passed.
- `apps/backend/tests/enrichment/handlers/answer-question-handler.test.ts`: Answer-question handler tests passed.
- `apps/backend/tests/enrichment/handlers/detect-question-handler.test.ts`: Question detection handler tests passed.
- `apps/backend/tests/enrichment/handlers/extract-bundle-intent-handler.test.ts`: Bundle intent handler tests passed.
- `apps/backend/tests/enrichment/handlers/generate-backlog-apology-handler.test.ts`: Backlog apology handler test passed.
- `apps/backend/tests/enrichment/handlers/is-product-request-handler.test.ts`: Product-request handler test passed.
- `apps/backend/tests/enrichment/handlers/recover-unclear-response-handler.test.ts`: Unclear-response recovery tests passed.
- `apps/backend/tests/enrichment/handlers/should-escalate-handler.test.ts`: Escalation handler tests passed.
- `apps/backend/tests/foreign-keys.test.ts`: Foreign-key and composite-reference tests passed.
- `apps/backend/tests/held-message-dedup.test.ts`: Held-message deduplication test passed.
- `apps/backend/tests/helpers/account-env.ts`: Account test environment helper was exercised by CLI tests.
- `apps/backend/tests/helpers/tenancy.ts`: Tenant fixture helper was exercised by tenant, migration, and HTTP tests.
- `apps/backend/tests/interrupted-transition.test.ts`: All interrupted-transition scenarios passed with NODE_ENV=test.
- `apps/backend/tests/llm-service.test.ts`: LLM service tests passed in the full test run.
- `apps/backend/tests/maintenance-freeze.test.ts`: All maintenance-freeze scenarios passed with NODE_ENV=test.
- `apps/backend/tests/migration.test.ts`: All 58 migration tests passed.
- `apps/backend/tests/mock-provider.test.ts`: Mock provider tests passed in the full test run.
- `apps/backend/tests/notification-routing.test.ts`: Notification routing scenarios passed with NODE_ENV=test.
- `apps/backend/tests/operations-audit.test.ts`: Operations audit scenarios passed with NODE_ENV=test.
- `apps/backend/tests/private-assets.test.ts`: Private asset authorization tests passed.
- `apps/backend/tests/recovery.test.ts`: Provider outage recovery tests passed.
- `apps/backend/tests/seed-images.test.ts`: All 7 seed-image tests passed.
- `apps/backend/tests/seeding.test.ts`: All 4 tests passed when run alone; one full-suite timeout occurred under load.
- `apps/backend/tests/setup.ts`: Throwaway DB/upload/private directories were verified by database and storage tests.
- `apps/backend/tests/simulator-replay.test.ts`: All simulator replay and per-number isolation tests passed.
- `apps/backend/tests/storage-path-guard.test.ts`: Storage traversal/symlink guard tests passed.
- `apps/backend/tests/storage-paths.test.ts`: Storage path derivation tests passed.
- `apps/backend/tests/suspended-tenant-processing.test.ts`: Suspended-tenant queue, reports, and adapter tests passed with NODE_ENV=test.
- `apps/backend/tests/tenant-http.test.ts`: Tenant HTTP authorization suite passed.
- `apps/backend/tests/tenant-isolation.test.ts`: Tenant isolation suite passed.
- `apps/backend/tests/tenant-scope-guard.test.ts`: Tenant scope guard tests passed.
- `apps/backend/tests/test-database.test.ts`: Throwaway DB and connection identity tests passed.
- `apps/backend/tests/uploads.test.ts`: Upload and asset tests passed in the full test run.
- `apps/frontend/src/app.d.ts`: Frontend type declarations compiled and checked.
- `apps/frontend/src/lib/components/conversations/conversation-item.svelte`: Conversation item component compiled in the production build.
- `apps/frontend/src/lib/components/conversations/conversation-list.svelte`: Conversation list/channel selection compiled and built.
- `apps/frontend/src/lib/components/shared/dashboard-nav.svelte`: Dashboard navigation compiled and built.
- `apps/frontend/src/lib/state/auth.svelte.ts`: Auth state compiled and passed frontend checks.
- `apps/frontend/src/lib/state/tenant-switching.test.ts`: All 6 tenant-switching tests passed.
- `apps/frontend/src/lib/state/tenant-switching.ts`: Tenant selection state compiled and passed frontend tests.
- `apps/frontend/src/routes/dashboard/admin/settings/+page.svelte`: Admin settings page compiled in frontend check/build.
- `apps/frontend/src/routes/dashboard/conversations/+page.svelte`: Conversation dashboard page compiled and built.
- `apps/frontend/src/routes/dashboard/conversations/[phone]/+page.server.ts`: Conversation server load compiled and built.
- `apps/frontend/src/routes/dashboard/conversations/[phone]/+page.svelte`: Conversation detail page compiled and built.
- `apps/frontend/src/routes/dashboard/orders/[orderId]/+page.svelte`: Order detail page compiled and built.
- `apps/frontend/src/routes/dashboard/personas/+page.server.ts`: Persona page server load compiled and built.
- `apps/frontend/src/routes/dashboard/personas/create/+page.server.ts`: Persona creation server action compiled and built.
- `apps/frontend/src/routes/dashboard/reports/+page.server.ts`: Reports server load compiled and built.
- `apps/frontend/src/routes/dashboard/simulator/+page.server.ts`: Simulator server load compiled and built.
- `apps/frontend/src/routes/dashboard/simulator/+page.svelte`: Simulator page compiled and built.
- `bunfig.toml`: Root Bun test preload points at backend test setup.
- `package.json`: Workspace scripts and account command wiring inspected.
- `packages/core/src/conversation/types.ts`: Core conversation types compiled with backend/frontend.
- `packages/types/src/catalog.ts`: Catalog types compiled and passed catalog tests.
- `packages/types/src/events.ts`: Event types compiled with backend/frontend.
- `packages/types/src/index.ts`: Shared tenancy/conversation types compiled.
- `readme.md`: Documentation matches the new storage, secret-generation, tenancy, and CLI flows; admin password mismatch is reported separately.
- `scripts/generate-token.ts`: Webhook, secrets, session, API, and JWT presets were inspected and compile correctly.

## Reviewer's report

Findings

- `apps/backend/src/adapters/whatsapp/index.ts:126`: adapter failures return `null`, but `WhatsAppService` resolves normally after logging `failed`. The executor then commits conversation state/events and workers mark inbox/held messages processed, losing customer replies without retry.
- `apps/backend/src/domains/analytics/index.ts:47`: `created_at` is stored as integer milliseconds, but the funnel query binds ISO strings. Events in the requested range are omitted; reproduced output: `[{"c":0}]`.
- `apps/backend/src/domains/reports/index.ts:40`: daily reports bind ISO strings against integer/mixed `last_activity_at` values, so valid conversations can be absent from exported reports.
- `apps/backend/src/routes/admin/users.ts:84`: HTTP user creation accepts any non-empty password, and reset accepts six characters at line 232, bypassing the shared 12-character policy.
- `apps/backend/src/adapters/whatsapp/parsers/cloud-api-parser.ts:20`: unsupported WhatsApp message types default to `text` with an empty body, so reactions, locations, or stickers can be queued as empty customer messages.
- `apps/backend/src/conversation/locks.ts`: the required brief does not state the complete states, transition owners, and timing for the changed lock/queue/session/idempotency state. `code.md` explicitly treats that omission as a defect.
- `apps/backend/package.json:12`: the default test script loads `.env` without forcing `NODE_ENV=test`; this selects `DevAdapter`, causing changed tests that mock Cloud API responses to fail or time out. Explicit `NODE_ENV=test` passes the targeted suites.

Verification

`git diff --check`, backend TypeScript compilation, frontend build/check, migration tests (58/58), tenant isolation/HTTP tests, storage tests, account tests, and frontend tenant-switching tests passed. Under `NODE_ENV=test`, the targeted maintenance, notification, lock, interrupted-transition, operations, and suspended-tenant suites passed 59/59.

The default command produced, verbatim:

```text
(fail) processing held messages while a freeze is on > a tenant admin whose own business is frozen > goes through again once the freeze is lifted [5007.46ms]
  ^ this test timed out after 5000ms.
```
