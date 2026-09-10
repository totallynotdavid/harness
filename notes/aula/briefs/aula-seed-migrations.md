# aula-seed-migrations

`pnpm db:seed` fails on a database that has never had migrations applied.

    rm -rf .data/dev-db
    pnpm db:seed

    error: relation "auth.user" does not exist
    code: 42P01
    query: delete from "auth"."user"

Run `pnpm dev` or `pnpm build` once first and the same seed succeeds. That
is the workaround people are using without knowing it, which is why this has
gone unnoticed.

## Cause

`server/database/seed.ts` calls `useDb()`, which opens the embedded PGlite
database but applies nothing. Migrations run only from
`server/plugins/migrate-dev-db.ts`, and a Nitro plugin does not run for a
standalone `tsx` script. So the script gets a connected but empty database
and its first `delete from` hits a table that was never created.

`useDevMigrator()` already exists in `server/utils/db.ts` and returns exactly
the function needed here. Nothing new has to be written; the seed script has
to call it before it touches a table.

## Scope

Fix the ordering so `pnpm db:seed` works against an empty data directory.
Check whether any other standalone script under `scripts/` has the same
assumption.

This is not caused by the recent close-db work. It predates it: the seed
script has never referenced a migrator, at any commit.

## Verify

    rm -rf .data/dev-db && pnpm db:seed && echo OK

That must pass from a clean checkout with no prior `pnpm dev` or `pnpm build`.
