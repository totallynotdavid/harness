# aula-lighthouse: budget the page the budget was written for

You own `.github/` and nothing else. Do not touch `layers/`, the repository
root, or `server/`.

## Why this exists

`.github/lighthouse/lighthouserc.cjs` measures `/`, the authenticated
application shell. The performance budget it cites was written for
`/verificar/:code`, a prerendered document a stranger opens after scanning a
QR code off a printed certificate. That page did not exist when the config was
written. It exists now.

Read the config's own header first. It is honest about what it deferred and
why, and it names the exact change it was waiting for.

## Deliverable 1: budget the verification page

Add `/verificar/<code>` to the collected URLs and move
`resource-summary:script:size` back to `error` at `maxNumericValue: 51200`,
scoped to that route rather than applied globally. The shell will not meet
that number and is not supposed to.

`pnpm db:seed` produces a real certificate. Use a seeded code so the run
measures a page that renders, and make it obvious in the config where that
code comes from, so a future seed change does not silently start measuring a
404.

Leave `server-response-time` as a warning. A shared runner cannot hold an
absolute millisecond threshold without flaking, and the config says so.

## Deliverable 2: stop using `pnpm preview`

`startServerCommand` is `pnpm preview`. `nuxt preview` chdirs into `.output`,
which breaks the cwd-relative migrations path in `server/utils/db.ts`, so
every database-backed route 500s. `/` happens to be prerendered, which is the
only reason this has not failed yet. The verification page is not, so it will.

`playwright.config.ts` already solved this. Use the same approach and keep the
two consistent.

## Deliverable 3: the claim the budget cannot check

The header notes that "works with JavaScript disabled" cannot be asserted from
an LHCI run. The verification layer sets `noScripts: true` for
`/verificar/**`. Assert it where it can be asserted: a Playwright check with
`javaScriptEnabled: false` belongs in `test/e2e/`, which is outside your
ownership, so report what you would add rather than adding it.

## Verify

Run `pnpm lighthouse` locally in both colour modes before reporting done.
`CHROME_PATH` is set by the workflow; export it the same way if your shell
needs it. A config change you have not executed is not verified.
