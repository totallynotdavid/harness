# Comeau learnings — mapped to the mockup

Method: read AGENTS.md, fetched all 10 cited Josh Comeau articles, then checked
`src/index.css`, `src/components/*`, `src/pages/*` against each principle.
No source files changed.

## 1. Form-control typography inheritance (CSS reset)
Already applied: `button, input, select, textarea { font: inherit }`
(`src/index.css:38-43`). Matters here because the site's many text inputs
(`Contacto.tsx`, `CarritoDatos.tsx`, `CursoDetalle.tsx`) need the same metrics
as body copy and must avoid iOS's 16px auto-zoom trap on first tap.

## 2. Isolation-based stacking vs manual z-index numbers
Gap: no `isolation: isolate` anywhere. The sticky header claims `z-50`
(`Header.tsx:29`) and the WhatsApp FAB claims `z-40` (`Contacto.tsx:19`) as
independent guesses. It works today by coincidence; the next overlay (a toast
for the forms the prior scout flagged as unwired) has no guarantee it will
layer correctly without a manual number war.

## 3. Rem-driven responsive type vs pixel-locked sizes
Already applied: headings/body route through rem-based `clamp()` tokens
(`index.css:78-124`), and Tailwind v4's own breakpoints are rem-based — a
user who enlarges browser text gets a genuinely more compact layout instead
of frozen text beside a viewport-only breakpoint.

## 4. Full-bleed via shared grid lines vs one-off tracks
Partial: four two-column layouts each hardcode their own pixel track —
`grid-cols-[387px_1fr]`/`[420px]`/`[405px]`/`[1fr_387px]` (`Contacto.tsx:39`,
`CursoDetalle.tsx:180`, `Nosotros.tsx:313`, `CarritoDatos.tsx:117`) instead of
one shared content-grid pattern, so the "sidebar width" is defined four times
and can silently drift.

## 5. Flexbox `min-width:0` for shrinkable children
Already applied broadly: `FormField.tsx:32,101`, `Header.tsx:31`,
`CourseCard.tsx:24,96`, and the course filters (`CursosDiplomados.tsx:41,58,79`)
all guard long Spanish labels against overflow.

## 6. Container queries for component-local layout
Gap: zero `@container` usage. `Noticias.tsx:45` switches the featured-story
card `flex-col`→`lg:flex-row` purely on viewport width even though it sits
inside a fixed `max-w-content` column — reused in a narrower slot (e.g. a
future "related news" rail) it would misjudge its own available space.
`CourseCard`/`NewsCard` dodge this only because they're always `max-w-card`.

## 7. prefers-reduced-motion as a hard gate
Already applied at the CSS layer (`index.css:126-139`), and there's no
framer-motion or scroll-driven JS animation anywhere in `src/` to bypass it —
fully load-bearing for hover transitions like `CourseCard.tsx:41`.

## 8. Margin collapse avoided by construction
Already good: section rhythm runs through `.section-space`/`.section-gutter`
padding and flex/grid `gap`, not sibling margins — collapse can't happen
inside Grid/Flexbox anyway, so AGENTS.md's "prefer gap" rule already
sidesteps the hazard class entirely.

## 9. Pixel-perfection via transform, not layout shifts
Already applied: optical centering uses `-translate-y-1/2`/`-translate-x-1/2`
(`CursosDiplomados.tsx:74,95`, `Contacto.tsx:127`) rather than negative
margins, so nudging one element doesn't drag its siblings.

## 10. CSS variables as the single source of brand truth
Largest gap found: ~70 raw hex literals across 16 files (`Nosotros.tsx` alone
has 17) duplicate colors absent from the 8-token `@theme` block
(`index.css:3-22`) — `#143769`, `#516279`, `#7f7e7e`, `#eaf2f7` recur as
arbitrary values (`Nosotros.tsx:242,256,267,304`, `CursoDetalle.tsx:171,206,207`,
`Home.tsx:342,399,417`) instead of `--color-cicat-*` tokens. This defeats the
exact mechanism Comeau describes: a brand-color change means grepping dozens
of call sites, not editing one variable.

## Top 3 new fixes (not already in ux-refine-scout.md)
1. **Tokenize the untokenized brand colors** — `#143769`, `#516279`,
   `#7f7e7e`, `#eaf2f7`, `#f7f7f7` — into `@theme`. Highest leverage; touches
   every page and is the biggest latent maintenance risk in the codebase.
2. **Layer and hue-match shadows** instead of flat `shadow-lg`/`shadow-sm`
   (`CourseCard.tsx:41`, `NewsCard.tsx:15`, `Header.tsx:56`,
   `NoticiaDetalle.tsx:69`) — cheap, additive, raises perceived polish
   site-wide on a health-training brand that leans on trust and credibility.
3. **Add an `isolation: isolate` boundary** at the app root before the next
   overlay (toast, modal) stacks on top of the existing header/FAB z-index
   pair — pre-empts a stacking bug that's currently latent, not yet triggered.
