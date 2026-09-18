# UX refine scout — findings

Method: static-code audit against `AGENTS.md` (read in full) — no browser-capable
tool was available in this environment, so routes were not rendered visually.
`bun install`, `bun run build`, `bun run lint`, `bun run format:check` all **pass**
cleanly (build: 58 modules, no TS errors; lint: 0 issues; format: all 50 files
correctly formatted). No `href="#"` or dead-onClick handlers were found anywhere
in `src/`.

## Quick wins

1. **Three lead-capture forms submit nothing** (medium). `Contacto.tsx:59-108`
   and the "Solicitar información" form in `Home.tsx:513-560` are plain
   `<form>` elements with no `onSubmit`, no `useState`, no `action`. Clicking
   "Enviar" triggers the browser's native GET submit → full-page reload with no
   feedback. Compare `CursoDetalle.tsx:352-451`, which uses the *identical*
   field set and *is* fully wired (`handleLeadFormSubmit`, `role="status"`
   success message, reset link) — proving the pattern exists in this codebase
   and these two are regressions/oversights, not a design choice. Violates
   AGENTS.md "Forms exist to help users reach an outcome" and the
   confirmation-message rule.

2. **"Ver aquí" consent links go nowhere** (small). In every consent checkbox
   (`Contacto.tsx:90,98`, `Home.tsx` lead form, `CarritoDatos.tsx:223,237`,
   `CursoDetalle.tsx` lead form) "Ver aquí" is a `<span className="font-bold">`,
   not a link — no href, not even `#`. Same for the four `FOOTER_LEGAL_LINKS`
   strings in `footer.ts:44-49`, rendered as inert `<li>` text in
   `Footer.tsx:83-88`. There is no privacy/terms route anywhere in
   `router.tsx`. Real marketing sites always make legal links clickable, even
   to a placeholder page.

3. **Contact details aren't tappable** (small). `ContactInfoItem.tsx:12-17`
   and the header's phone/email (`Header.tsx:38,47`) render phone/email as
   plain `<p>` text instead of `tel:`/`mailto:` links — a baseline pattern on
   any contact page, especially on mobile.

4. **"AULA VIRTUAL" looks like a live nav item but is inert** (small).
   `Header.tsx:86-91,137-142` renders it as a `<span>` styled identically to
   an active button, with only a `title` tooltip ("próximamente") as the
   explanation. `title` isn't reliably exposed to touch or screen-reader users,
   so on mobile it just silently does nothing when tapped. AGENTS.md: "Explain
   the constraint near the control" — needs a visible, non-hover cue (e.g. a
   "Próximamente" pill) rather than a hover-only tooltip.

## Larger / redesign-worthy items

5. **Verificación de Certificado has no result state at all** (large). This is
   the whole point of `VerificacionCertificado.tsx:48-64`: a DNI form with a
   "Verificar" button and **zero** `onSubmit`, `useState`, loading, empty, or
   error UI — the page never shows a certificate result under any input.
   Directly hits the brief's callout for "missing loading/empty/error states."
   Unlike the other unwired forms, there's no sibling implementation elsewhere
   to copy from — this needs a small feature build (mock lookup +
   found/not-found/loading states), not just wiring an existing handler.

6. **No privacy/terms/refund pages exist**, only referenced text (medium/large,
   depends on scope). Ties findings #2 and #5's "Política de Privacidad"
   references together — either add minimal routes or drop the promises. This
   is a content/routing gap, not a single-component fix, so it's flagged here
   rather than fixed in this scout task.

## What's already solid (no action needed)

- `CarritoDatos.tsx` / `CarritoPago.tsx` checkout flow: validates on submit
  (not per keystroke), preserves input across steps via storage, stable error
  space, `role="alert"` errors, file-upload validation — matches AGENTS.md
  forms guidance closely and is a good model for fixes above.
- `CursosDiplomados.tsx`: live search/filter with a proper empty state
  ("No se encontraron cursos...") — matches course-marketplace faceted-search
  conventions.
- Course/news cards, headings (`h1` via `PageHero`), and per-route
  `document.title` (`Layout.tsx:6-24`) are consistent and correctly scoped.

No source files were modified for this report.
