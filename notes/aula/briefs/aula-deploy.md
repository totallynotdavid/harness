# aula-deploy

Containerise aula so it can run on a self-hosted box: the Nuxt server, a real
Postgres, and the `typst` CLI the certificates layer shells out to.

## Why Docker, when the reference repo does not

`npmx-dev/npmx.dev` deploys to Vercel and carries a `vercel.json` and no
Dockerfile. Aula diverges on purpose, for two reasons that do not apply there:

- Certificates render by spawning the `typst` binary. A serverless function is
  a poor host for a 54 MB executable that has to be on `PATH`.
- Aula owns durable data. It needs a Postgres it keeps, not a request-scoped
  connection to somewhere else.

What does carry over from npmx is the Node and pnpm setup and the pinned,
SHA-referenced actions already used in `.github/workflows/ci.yml`.

## The one that will bite you

`.output/` does not contain the fonts. Verified: after `pnpm build`,

    find .output -name '*.ttf' | wc -l   # 0

`server/render/fonts.ts` resolves them at runtime against `process.cwd()`:

    const ASSETS_DIR = path.resolve(process.cwd(), 'layers/certificates/assets/fonts')

So an image built the usual Nitro way, copying only `.output/`, starts fine,
serves pages fine, and fails on the first certificate render. The image must
also carry `layers/certificates/assets/fonts/*.ttf`, and the working directory
at runtime must be the one those paths resolve against.

Decide deliberately between two fixes and say which you chose:

1. Copy the fonts into the image and set `WORKDIR` so `process.cwd()` matches.
2. Point the existing env vars (`AULA_CERT_FONT_SANS_MEDIUM`,
   `AULA_CERT_FONT_SANS_BOLD`, `AULA_CERT_FONT_SCRIPT_BOLD`) at absolute paths
   inside the image. `fonts.ts` already supports this.

The second is less coupled to the working directory. Confirm it works before
preferring it on that argument alone.

## Typst in the image

`mise.toml` pins `typst = "0.15.1"`. The image must install that same version,
not "latest". Either run mise in the build, or download the pinned release
directly. If you download it directly, the version now lives in two places, so
say how they stay in step.

## Postgres and migrations

`DATABASE_URL` selects the real driver. When it is set, migrations do not run
at boot by design (`server/plugins/migrate-dev-db.ts` returns early), so
applying them is a deliberate release step:

    pnpm db:migrate

Run it as its own step, not from the app's entrypoint. Two replicas starting
at once must not both migrate.

## Runtime

- Start with `node .output/server/index.mjs`. Not `nuxt preview`, which
  chdirs into `.output` and breaks any cwd-relative path, including the fonts
  above and `drizzle/`.
- Required env: `DATABASE_URL`, `BETTER_AUTH_SECRET`, `BETTER_AUTH_URL`.
  `BETTER_AUTH_SECRET` is not optional; prerender and auth both fail without it.
- Do not bake secrets into the image.

## Verify

The build passing is not evidence here. Prove the running container:

1. `docker compose up`, then request a page that hits the database.
2. Render one real certificate through the container and open the PDF. This is
   the check that catches the font problem; nothing cheaper does.
3. Restart the container and confirm the data is still there.
