# transactions conventions

Initialized from: README.md

Project-specific rules for cap check and review.
Project instruction files remain authoritative.

## Surfaces

Files that should change together.

```surfaces
# changed-pattern -> required-pattern
# ^src/cli/ -> ^docs/
```

## House norms

Project-specific rules that change or extend the default checks.

## Subsystem invariants

System rules that cannot be detected from a diff alone.

## Gate-miss ledger

cap deliver writes an entry for every blocker or major finding raised after an
earlier gate round passed the same bytes. Add human-caught misses by hand.

- 2026-09-17 rqueue-task-declare: gate A (haiku) passed `src/rqueue/migrations/0004_retry_policy.sql` at eaa7a80; gate B (luna) then found, in the same bytes: [major] `src/rqueue/migrations/0004_retry_policy.sql:10` The new shared retry-policy state lacks a complete written invariant defining all states and which producer, worker, or operator transition may move between them. The change only partially documents NULL versus persisted policy behavior, leaving cross-process ownership and consistency rules under-specified. (finding 6c3902ec, missed by gate A)
