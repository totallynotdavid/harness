# aula-build-hang

`pnpm build` prints `✨ Build complete!` and then never exits. The work is
finished and correct; the process just will not end. Kill it and the build
output in `.output/` is complete and usable.

## Reproduce

    rm -rf .data/dev-db
    pnpm db:seed          # or run the app once so the database has data
    pnpm build            # hangs after "Build complete!"

With an empty or missing `.data/dev-db` the same build exits normally in about
20 seconds. That is the whole difference. Measured five times, three hangs
against a populated directory and two clean exits against a fresh one.

## What it is not

Three plausible causes were tested and ruled out.

It is not memory pressure or a flaky machine. The process sits at a steady
1.3 GB and sleeps; it is not working.

It is not esbuild's persistent `--service` child. Killing that child leaves the
build process running.

It is not the open PGlite file descriptors. About fifty stay open on the data
directory, but open descriptors are not libuv handles, and
`process.getActiveResourcesInfo()` shows the filesystem request queue draining
to zero after the build finishes.

## What the evidence points at

Sample the active handles with `--require` a script that calls
`process.getActiveResourcesInfo()` on an unref'd interval. During the build:

    {"FSReqCallback":2270,"FSReqPromise":50,"PipeWrap":1,"Timeout":1}

After `Build complete!`:

    {"PipeWrap":1,"Timeout":1}

`Timeout` is the probe's own unref'd interval and cannot hold the loop open.
One `PipeWrap` is left, and it is what keeps the process alive. Find out which
pipe it is.

A second fact worth starting from: Nitro's `close` hook never fires in this
path. A plugin that registers `nitroApp.hooks.hook('close', ...)` logs its
registration *after* prerendering has already finished, and the handler is
never called, even though `nitropack/dist/core/index.mjs` calls
`await closePrerenderer()` at the end of prerendering. So the plugin instance
holding the database is not the instance the prerenderer closes. Understanding
why is likely the same question as which pipe is left open.

## Note on instrumenting it

`async_hooks` is heavy enough to distort this build. With a PIPEWRAP `init`
hook enabled the process climbed past 2 GB and had not finished building after
45 seconds, so the hang could not be reached. Capture the creation stack on a
smaller reproduction, or use a sampling approach that does not enable
`async_hooks` for the whole build.

## Why it matters

`cap verify` runs `pnpm build` last. Until this is fixed the gate cannot pass
on a developer machine that has ever run the app, which is every machine. CI
does not see it because the runner tears the process down when the job ends, so
a build that never exits looks exactly like one that does.

## Out of scope

`server/utils/db.ts` now exports `closeDb()`, and `seed.ts` and
`render-stored.ts` use it instead of `process.exit(0)`. That is a separate,
proven change and is not a fix for this bug. Do not assume it is.
