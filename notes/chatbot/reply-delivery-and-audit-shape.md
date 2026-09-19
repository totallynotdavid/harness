# Reply delivery and the account audit row: shape

Two defects in `defects.md` need a design choice before code. Each has a
recommendation. Correct it before a task starts.

## Lost replies on a failed send

Today the adapters return `null` on an HTTP error, a network error or a timeout.
The service records `failed` and resolves, the phase is already persisted, and the
inbox marks the inbound message processed. The customer's reply is lost.

Recommendation: an outbox.

- A command that sends writes an outbound row in the same transaction as the phase
  change: tenant, channel account, conversation, sequence, payload, status
  `pending`, attempts, next attempt time.
- One sender drains each conversation in order. Success sets `sent` and stores the
  provider message id.
- Transient failures (network, timeout, 5xx, 429) retry with backoff. Permanent
  failures (4xx: bad token, unreachable recipient, outside the 24-hour window) set
  `failed` at once.
- A `failed` row, or one out of retries, puts the conversation in human attention
  with reason `reply_undeliverable`, using the handoff mechanism from #119.
- The Cloud API has no idempotency key, so a timeout after the server accepted can
  send twice. Retry a timeout once and accept the rare duplicate over a lost reply.

Decide: the retry budget, whether an exhausted reply hands off to a person
(recommended) or is dropped, and whether Meta's delivery-status webhooks are
consumed now or later (recommended: later).

## No audit row for `bun run account`

`audit_log.user_id` is NOT NULL (`schema.sql:434`), so creating or promoting an
account from the terminal leaves no record. Promotion grants cross-tenant powers.

Recommendation: rebuild `audit_log` with a nullable `user_id`, a nullable
`tenant_id` and a required `actor` (`user:<id>` or `cli:<os user>`). The account
command writes one row per create and promote, naming the target username.
SQLite cannot drop NOT NULL in place, so the rebuild is a boot-time migration that
copies the rows.

Decide: nothing, unless recording the operating-system user is not wanted.
