# Gate B: vendeya-webhook-signature

luna reviewed the changes since abb6cc8a7a5d, with HEAD at abb6cc8a7a5d (fingerprint bbec2af70628). Verdict: FAIL.

## Findings

- [major, confirmed] `apps/backend/src/routes/webhook.ts:285` The new mandatory signature check rejects the existing notifier path: apps/notifier/src/message-forwarder.ts POSTs unsigned JSON, so notifier messages receive 401 before parsing or routing and never reach message_inbox. (finding 80258f46)

## Checked

- `.env.example`: Verified WHATSAPP_APP_SECRET is documented.
- `.env.production.example`: Verified production configuration documents the required app secret.
- `apps/backend/src/index.ts`: Verified missing-secret startup warning behavior.
- `apps/backend/src/routes/webhook.ts`: Verified HMAC validation, raw-body parsing, status handling, and covered routing tests.
- `apps/backend/tests/foreign-keys.test.ts`: Webhook requests are signed; foreign-key tests pass.
- `apps/backend/tests/held-message-dedup.test.ts`: Signed delivery and deduplication tests pass.
- `apps/backend/tests/setup.ts`: Verified isolated test storage and test app-secret setup.
- `apps/backend/tests/tenant-isolation.test.ts`: Signed webhook routing and tenant-isolation tests pass.
- `apps/backend/tests/unknown-message-types.test.ts`: Signed unknown-type handling tests pass.
- `apps/frontend/src/routes/api/webhook/+server.ts`: Verified signature forwarding, timeout, status relay; svelte-check passes.
- `packages/core/src/validation/affirmation.ts`: Verified linear trailing-punctuation stripping.
- `packages/core/tests/affirmation.test.ts`: All affirmation and performance tests pass.
- `readme.md`: Verified external webhook signature behavior is documented.
- `apps/backend/tests/helpers/webhook.ts`: Verified test HMAC generation matches backend validation.
- `apps/backend/tests/webhook-proxy.test.ts`: All proxy forwarding, retry, timeout, and error tests pass.
- `apps/backend/tests/webhook-signature.test.ts`: All signature acceptance and rejection tests pass.
