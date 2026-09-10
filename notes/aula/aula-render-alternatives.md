# Is Chromium the right PDF engine for aula's certificates?

Scout task. Nothing in the repository was changed; all experiments ran in a
scratch directory outside the worktree. Sample artifacts are saved next to
this report in `aula-render-alternatives-samples/`.

## Recommendation

**Replace Chromium with Typst.** It meets every hard requirement with
evidence, and it beats the current pipeline on every operational number
measured: an order of magnitude less memory, an order of magnitude smaller
deployment footprint, a comparable-or-faster cold start, and a cleaner
determinism story than the current timestamp-stripping regex. The two
non-negotiable requirements this task exists to check — real single-pass
text measurement, and byte-identical output — both hold up, not by
assertion but by rendering and re-measuring.

The cost is real and should be named plainly: this is a full rewrite of
`layers/certificates/server/render/template.ts` in Typst's own markup
language (nothing in the HTML/CSS ports over syntactically), and the fonts
directory's current promise — "swap a file, no code change" — breaks, since
Typst cannot load `.woff2` and the three font files need a one-time
conversion to `.ttf` plus a renaming step to keep the current
logical-family indirection. Both are bounded, one-time costs, not standing
architectural risk.

WeasyPrint and Satori+resvg were also built and tested to the same
standard. Both technically satisfy the five requirements, but each carries
a standing architectural liability that Typst does not: WeasyPrint requires
duplicating text-shaping logic in a second library with no built-in
drift-detection, and it turns out to need real system libraries after all
(see below) — the "no GUI libraries needed" promise doesn't survive contact
with a clean container. Satori's output has no embedded, selectable text at
all, permanently, by construction. Details for both are below for the
record, but neither is recommended over Typst.

## The requirements, and how each candidate did

Long holder name used for every shrink-to-fit test, matching the pipeline's
own regression test (`layers/certificates/test/auto-fit.test.ts`):

> María Fernanda de los Ángeles Rodríguez-Villanueva y Quispe Huamán Salazar

| Requirement | Chromium (current) | Typst | WeasyPrint | Satori + resvg |
|---|---|---|---|---|
| Exact 297×210mm page | Met | Met | Met | Met |
| Embedded fonts, Spanish diacritics | Met | Met, after ttf conversion | Met | Met, after ttf conversion + de-variabling |
| Embedded QR | Met | Met | Met | Met (as real vector paths) |
| Single-pass shrink-to-fit | Met (`scrollWidth`) | **Met**, via `measure()` | Met, via external HarfBuzz pre-shaping | "Met" only via a font-specific coincidence |
| Byte-identical output | Met, via regex strip | Met, via native flag | Met, via a font-timestamp monkeypatch | Met |

### Shrink-to-fit — the hard requirement, per candidate

This is the reason the pipeline moved off PDFKit in the first place, so
each candidate was checked for whether it can genuinely measure text in one
pass the way Chromium's `scrollWidth` does, or whether it quietly pushes
the problem back into iterative guessing.

- **Typst**: has a first-class `context { measure(...) }` API built for
  exactly this. Built the equivalent of `shrinkToFit` almost line-for-line:
  measure the holder-name at its base size, compute one scale factor
  (`available / measured * 0.98`, the same formula and the same 2% margin
  as the current JS), apply it once. For the long name: unshrunk width
  measured at 421mm against 237mm available (would overflow ~1.8x);
  computed scale 0.5516; the shrunk text re-measured at 232.26mm, fitting
  with margin to spare. No loop, no retry — this is the same algorithm the
  current pipeline runs, in a different language.
- **WeasyPrint**: has no live layout to query, so the text was pre-shaped
  with the real `script-bold` font file via HarfBuzz (`uharfbuzz`) before
  handing HTML to WeasyPrint, and the resulting scale factor applied once.
  This works — WeasyPrint links the same HarfBuzz C library internally, so
  the external measurement and WeasyPrint's own rendering agreed to within
  ~0.1% — but a real bug surfaced along the way: `uharfbuzz` silently
  returns a wrong-but-plausible width (off by ~2.5×, in the
  under-shrinking direction) when handed a raw `.woff2` blob instead of a
  decompressed font, with no error. That is a duplicated, second
  text-shaping stack with no built-in check against the first, sitting
  directly on the one feature this task calls "the hard one."
- **Satori**: has no measurement API of any kind — not even an unsafe or
  private one. A single-pass measurement was still made to work, but only
  by an external font-metrics library (`fontkit`) predicting Satori's
  internal HarfBuzz-shaped width to within 0.04–0.05% — which held up
  *because this particular font has no GPOS/kerning tables*. That
  precondition is a property of the font file, not of Satori, and would
  need to be re-verified by hand for every font swap. Absent that
  coincidence, the only fallback demonstrated was rendering once, reading
  the actual width back out of the returned SVG, and re-rendering if it
  overflowed — the iterative guess-and-check loop this task was
  specifically checking whether a candidate could avoid.

### Determinism, per candidate

- **Chromium (current)**: not deterministic out of the box; the pipeline's
  `stripRenderTimestamp` regex-patches Chromium's wall-clock
  `/CreationDate` and `/ModDate` trailer fields after the fact. Works, but
  is a patch over a real source of nondeterminism.
- **Typst**: deterministic via a first-class `--creation-timestamp` CLI
  flag — no post-processing needed. Verified sha256-identical across two
  host renders and a third render inside a from-scratch container.
- **WeasyPrint**: the PDF trailer itself has no timestamps at all, but a
  second, well-hidden source of nondeterminism was found: the embedded font
  subset's `head.modified` field, stamped by `fontTools` during
  WeasyPrint's internal subsetting, buried inside a compressed object
  stream — invisible to a trailer-level regex. Fixed with a one-line
  monkeypatch of `fontTools.misc.timeTools.timestampNow`; verified
  sha256-identical afterward, including host-vs-container.
- **Satori + resvg**: deterministic; two full renders' SVG, PNG, and PDF
  outputs were all sha256-identical.

## Operational numbers

| | Chromium (current) | Typst | WeasyPrint | Satori + resvg |
|---|---|---|---|---|
| Cold start | 41.5ms median (browser launch only) | ~40–55ms per page | ~1.0s process (render itself ~0.17s) | ~163ms cold, ~122ms warm |
| Memory | idle 321MB / 1 render 457MB / 4 concurrent 790MB | ~30MB peak | ~63–78MB RSS | ~470–480MB RSS |
| Install / deployment size | 393MB browser cache + 61MB system libs = **~454MB** | 54MB static binary | ~48MB (site-packages) | ~31MB `node_modules`, plus a Rust `svg2pdf-cli` build |
| Survives a GUI-less container? | **No** — 25 missing shared libraries, hard failure (exit 127) until 21 Debian packages are installed | **Yes** — static binary, zero packages, byte-identical to host | **No, contrary to its own marketing** — `dlopen()` fails on `libgobject-2.0` etc. until 5 packages are installed | Yes — native binaries link only baseline glibc |

The Chromium numbers matter in context: `MAX_CONCURRENT_RENDERS = 4` was
explicitly sized, per the code's own comment, for a modest VPS. Four
concurrent renders already cost ~790MB just in Chromium's own process
tree, before the rest of the Nuxt server. Typst's four concurrent renders
would cost on the order of 120MB.

The "no GUI libraries" claim was tested for real, not assumed, for both
Chromium and WeasyPrint: a genuinely empty `debian:12-slim` /
`python:3.14-slim` container via podman, `ldd`/import failure captured,
then the exact missing packages installed and the fix confirmed. WeasyPrint
is lighter than Chromium, but the "WeasyPrint ≥53 dropped its system
dependency" framing is specifically wrong for text shaping — it still hard
depends on `libpango`, `libharfbuzz`, `libgobject-2.0`, `libfontconfig` at
import time, and WeasyPrint's own changelog signals that floor is growing,
not shrinking.

## Why not Satori (the SVG path)

Beyond the shrink-to-fit fragility above, Satori has a structural
disqualifier for a certificate: **it outlines all text into vector paths
at generation time.** The resulting PDF has no embedded fonts and no
selectable or searchable text, ever — not a tooling limitation to be fixed
later, but how Satori works. A certificate that is meant to be verified,
searched, and possibly copied from (a name, a verification code) losing
real text is a regression the task's requirements don't explicitly list
but that matters for this document type. Two more real costs came up
building it: the two heading fonts are variable fonts, and Satori's
bundled font parser crashes on their `fvar` table (fixed by statically
instancing each weight with `fontTools` first); and `resvg`'s own CLI has
no PDF output at all — the vector PDF path only worked by pulling in
Typst's own `svg2pdf-cli` as a second Rust dependency, one library
borrowed from the very candidate that doesn't need any of this.

## Why not WeasyPrint

WeasyPrint met every listed requirement, and if Typst did not exist it
would be a reasonable choice — it is a straightforward, well-documented
HTML/CSS engine and the migration path from the current template is
shorter than Typst's, since the CSS mostly ports over. It is passed over
here because Typst clears the same bar with less standing risk: no
duplicated text-shaping stack to drift out of sync, no system-library floor
to re-discover was wrong, and a cleaner determinism fix (a flag, not a
monkeypatch on a library internal).

## What the change would cost

- Rewrite `template.ts` as Typst markup — a genuine second implementation
  of the certificate layout, not a port. `browser-pool.ts` and its
  concurrency semaphore go away entirely; Typst has no warm-process model
  to manage, each render is a fresh, cheap process invocation, so the
  "one warm browser, capped concurrency" design this pipeline was built
  around no longer applies. Given per-render cost (~30MB, ~50ms), a
  concurrency cap may still be worth keeping for CPU fairness, but the
  memory pressure that motivated `MAX_CONCURRENT_RENDERS` in the first
  place is gone.
- One-time font conversion: `.woff2` → `.ttf` for the three self-hosted
  fonts via `fontTools`, plus a renaming step to preserve the current
  logical-family indirection (`Aula Certificate Sans` /
  `Aula Certificate Script`) that lets fonts be swapped without touching
  code — `fonts.ts`'s current design goal, currently free, becomes a
  one-time script instead.
- `renderCertificate.ts`'s `stripRenderTimestamp` regex is deleted outright
  and replaced by Typst's `--creation-timestamp` flag.
- `qr.ts` needs no change: the same inline SVG QR code embeds into Typst
  via `#image()`.
- Every existing test in `layers/certificates/test/` that asserts on PDF
  *behavior* (byte-identity, valid-PDF-shape, grade-line presence, etc.)
  needs re-pointing at the new renderer; `auto-fit.test.ts`'s specific
  browser-DOM assertions (`scrollWidth`/`clientWidth`/`getComputedStyle`)
  need rewriting against Typst's `measure()` output instead, though the
  behavior they guard — the regression this file exists for — carries over
  directly.
- Gotenberg was not evaluated as a candidate, per the task's own framing:
  it is Chromium in a container, so it would change how the dependency is
  packaged, not remove it.

## Proof

The top candidate's proof-of-concept: a Typst template
(`aula-render-alternatives-samples/certificado-typst-template.typ`)
rendering the long-name test case, non-overflowing, at
`aula-render-alternatives-samples/certificado-typst-long-name.pdf`
(sha256 `d028c23114e9bb225228534414dc45b7eeb26dcab46ee25d841ae59ea64afc38`,
confirmed identical across two host renders and one render inside a
from-scratch container).

## Tooling installed for this task

Installed on this machine via `mise` (global) and `pip`, for use in any
future `aula` worktree: `typst` (via `mise use -g typst`), `python@3.14`
(via `mise use -g python@3.14`), and `weasyprint` (via `pip install
weasyprint`, into that mise-managed Python). Recorded in
`config/tools/aula` so the next worktree has them without re-discovering
them.

No second problem was found in the current implementation itself —
`browser-pool.ts`, `renderCertificate.ts`, `template.ts`, `fonts.ts`, and
`qr.ts` all behave as documented and are already covered by tests that
passed during this evaluation (`renderCertificate.test.ts` and
`auto-fit.test.ts`, 8/8). Everything reported above is about the tradeoffs
of the rendering engine choice, not a defect in the code that uses it.
