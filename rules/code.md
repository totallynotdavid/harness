# Code rules

How code must read. Applies to every agent brief and every review gate.

## Readability

- Keep functions small, linear, and single-purpose.
- Use early returns to keep happy paths visible and indentation shallow.
- Avoid boolean mode arguments; split behavior into separate functions.
- Use one consistent domain term per concept across modules and APIs.
- Avoid generic names (`helper`, `util`, `manager`, `processor`) unless literal.
- Remove dead code, commented-out code, and ceremony without active value.
- Do not abstract coincidental similarity that has no shared reason to change.
- Keep side effects explicit and close to boundaries.
- Keep domain modules locally understandable without framework context.
- Validate at boundaries and return explicit errors with actionable context.
- Comments are allowed only for non-obvious intent or external API quirks. Full audit
  pass: `rules/comments.md`.

## Shared state

- Before a change touches state visible to more than one concurrent actor (a lock, a
  queue, a cache, a session, an idempotency key), the brief must state the full set of
  states and who is allowed to move which transition, when. A diff that adds or edits
  such state without that statement existing is a defect: fail the round and say what
  invariant is missing, not what line to patch. A narrow fix that closes one violation of
  an invariant nobody wrote down will not close the next one; the same file will keep
  coming back.

## Output

- Say what changed and what it cost; skip what you are about to do.
- Show failing output verbatim rather than describing it.
- No preamble, no recap of the request, no closing summary of a summary.
