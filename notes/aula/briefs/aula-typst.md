# aula-typst: replace Chromium with Typst as the PDF engine

You own `layers/certificates/` and nothing else.

## Why

`notes/aula/aula-render-alternatives.md` in the Captain repo is a scout
report that built and measured four candidates. Read it before you start.
The decision is made: Typst replaces Chromium. Your job is to carry it out,
not to re-open it.

The short version of why. Chromium costs 790MB across four concurrent
renders and 454MB of deployment image, and fails outright in a container
without 21 Debian packages. Typst costs roughly 120MB across the same four
renders, ships as a 54MB static binary, and runs in an empty container.

## The requirement that decides everything

`renderCertificate.ts` shrinks a long holder name to fit its box in one
measurement, using `scrollWidth` against `clientWidth`. That single-pass
measurement is why this pipeline exists in its current form: the system
being replaced used an iterative PDFKit measure-and-shrink loop.

Typst's `context { measure(...) }` is the equivalent. The scout proved it
with the same formula and the same 2% safety margin, on this name:

    María Fernanda de los Ángeles Rodríguez-Villanueva y Quispe Huamán Salazar

Unshrunk 421mm against 237mm available, scale 0.5516, re-measured 232.26mm.
A working template and its rendered PDF are next to the report in
`aula-render-alternatives-samples/`. Start from them.

If you find yourself writing a loop that renders, checks, and re-renders,
stop. That is the failure this whole design exists to avoid, and it is a
signal you have lost the measurement API, not a reason to iterate.

## The work

- Rewrite `template.ts` in Typst markup. This is a second implementation of
  the layout, not a syntactic port. Nothing in the HTML or CSS carries over.
- Delete `browser-pool.ts` and its concurrency semaphore. Typst has no warm
  process to pool; each render is a fresh, cheap invocation. Whether a
  concurrency cap is still worth keeping for CPU fairness is your call, but
  say which you chose and why. The memory pressure that motivated
  `MAX_CONCURRENT_RENDERS` is gone.
- Delete `stripRenderTimestamp` and its test. Typst's `--creation-timestamp`
  makes output deterministic natively instead of by rewriting bytes after
  the fact.
- Convert the three `.woff2` files in `assets/fonts/` to `.ttf`. Typst
  cannot read `.woff2`.
- `qr.ts` needs no change. The same inline SVG embeds through `#image()`.

## Do not lose the font indirection

`fonts.ts` exists so the template only ever names two logical families,
`Aula Certificate Sans` and `Aula Certificate Script`, and which file backs
them is a deployment detail set per environment variable. Its header says
buying the real DINPro and Script MT Bold licences must swap a file, never
this code. That property is the point of the module and it must survive the
migration. If Typst forces a different mechanism, keep the property and say
how.

## Tests

Every test in `test/` that asserts on PDF behaviour re-points at the new
renderer: byte-identity, valid PDF shape, the grade line, and the rest.

`auto-fit.test.ts` is the one that matters. Its current assertions poke at
`scrollWidth`, `clientWidth` and `getComputedStyle`, all of which are gone.
The regression it guards does not go away with them. Rewrite it against
`measure()` so it still fails if a long name overflows.

`browser-pool.test.ts` goes when the pool does.

## Verify

`pnpm test`, `pnpm lint`, `pnpm typecheck`, `pnpm build`, and render a real
certificate from seeded data. Render the long name above and confirm it fits.
Render the same input twice and confirm the bytes are identical.

Report the new numbers: image size, memory per render, time per render.
