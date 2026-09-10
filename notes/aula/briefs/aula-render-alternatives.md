# aula-render-alternatives: is Chromium the right PDF engine?

This is a scout task. Read the code, run experiments in a scratch directory,
and write a report. Change nothing in the repository.

## The question

`layers/certificates/server/render` renders certificates by launching a real
headless Chromium through Playwright and calling `page.pdf()`. That single
dependency drives the whole deployment: the production image must carry a
browser and the memory to keep one warm, and it has already broken CI twice
by being absent.

The captain wants to know whether a better option exists. Not whether one
exists in the abstract: whether one exists that meets what this pipeline
actually needs, at a cost worth the change.

## Read these first, they define the requirements

- `render/browser-pool.ts`: one warm browser per process, renders capped at
  `MAX_CONCURRENT_RENDERS`, explicitly sized for a modest VPS.
- `render/renderCertificate.ts`: in particular `shrinkToFit`, which measures
  `scrollWidth` against `clientWidth` in the live page to shrink overflowing
  text in one pass. Its comment says this is the whole reason the rebuild
  moved off the old system's PDFKit measure-and-shrink loop.
- `render/template.ts`, `render/fonts.ts`, `render/qr.ts`: the HTML template,
  embedded fonts, and the QR code.
- The determinism note at the top of `renderCertificate.ts`: Chromium stamps
  wall-clock time into the PDF trailer, and the pipeline overwrites it so the
  same input produces the same bytes.

## What the answer has to satisfy

Any candidate must handle all of these, and you must demonstrate it, not
assert it:

- Print-exact page geometry at the size in `PAGE_SIZE_MM`.
- Embedded fonts, with correct Spanish diacritics.
- An embedded QR code.
- Text that shrinks to fit its box when a long name or course title would
  otherwise overflow. This is the hard one. Say plainly whether a candidate
  can measure text at all, or whether it would push the problem back to an
  iterative guess.
- Byte-identical output for identical input.

Then report the operational side: image size, memory per render, cold start,
and whether it survives a container with no GUI libraries.

## Candidates worth testing

At least Typst, WeasyPrint, and an SVG path such as Satori with resvg. Add
any you think stronger. Include "keep Chromium" as a real candidate and give
it the same scrutiny: the honest answer may be that it stays.

Do not evaluate Gotenberg as an escape from Chromium. It is Chromium in a
container, so it changes the packaging, not the dependency. Say so if you
mention it.

## Deliverable

A report with a recommendation and the reasoning that produced it, including
what the change would cost and what would have to be rewritten. Build a small
proof for the top candidate: render one certificate-shaped page with a long
name that must shrink, and put the resulting file path in the report.

If the answer is "Chromium stays", say that clearly and say why, with the
measurements that support it. A negative result is a real result here.
