# Next UX refinement round — plan

Sources: `notes/mockup/ux-refine-scout.md` (code audit against `AGENTS.md`),
`notes/mockup/comeau-learnings.md`, `notes/mockup/silver-learnings.md` (the
Comeau/Silver articles AGENTS.md cites, fetched and checked against `src/`).

## Finding

`src/` has only `pages/`, `components/`, `content/` — no `hooks/`, no `lib/`.
The Comeau/Silver principles live as prose in `AGENTS.md`, so each page-porting
round has to recall and reapply them by hand. Some do, some don't:

- 8 files hand-roll form/async state independently. `CarritoDatos.tsx` gets
  Silver's validation rules right; `CursoDetalle.tsx`, `Home.tsx`,
  `Contacto.tsx`, `VerificacionCertificado.tsx` each reinvent it, and three of
  the five get it wrong (weak or missing validation, no submit handler at all).
- 8 separate hand-rolled `role="status"`/`role="alert"` blocks instead of one
  shared status-message component.
- 4 files hardcode 4 different pixel sidebar-grid tracks
  (`grid-cols-[1fr_387px]`, `[405px_1fr]`, `[387px_1fr]`, `[1fr_420px]`)
  instead of one shared content-grid primitive.
- ~70 raw hex-color literals across 16 files bypass the `@theme` token block.
- Flat, non-layered shadows; no z-index/`isolation` scale (header `z-50` and
  WhatsApp FAB `z-40` only avoid collision by luck).

## Plan: build the missing primitives, then wire pages onto them

1. **`ux-design-system`** — build these primitives and migrate one real
   consumer of each to prove it (not scaffolding left unused):
   - `src/hooks/useFormSubmission.ts` — submit-gated validation, per-field
     error map, never disables submit, exposes an async/loading relabel
     state. Migrate `CarritoDatos.tsx` onto it.
   - `src/components/StatusMessage.tsx` — one alert/status component,
     replacing the 8 hand-rolled instances. Migrate one existing usage.
   - `src/components/ContentGrid.tsx` (or a `.content-grid-sidebar` utility)
     — one shared two-column sidebar grid, replacing the 4 divergent tracks.
   - Extend `index.css`'s `@theme`: the missing color tokens, a named
     elevation scale (replacing flat `shadow-lg`/`shadow-sm`), a named
     z-index/`isolation` scale.
   - `src/components/NavAffordance` (or extend `Button`) — a focusable,
     `aria-disabled`, visibly-labelled "coming soon" pattern, replacing the
     `title`-tooltip span used for AULA VIRTUAL.

   This is the foundation; nothing below starts until it's delivered.

2. **`ux-quickwins`** — wire onto the new primitives: Home/Contacto/CursoDetalle
   lead-capture forms (submit + feedback via `useFormSubmission` +
   `StatusMessage`), the AULA VIRTUAL affordance (`NavAffordance`), consent
   "Ver aquí" links and footer legal links made real, contact phone/email as
   `tel:`/`mailto:` links, redundant required-asterisks removed, placeholder
   text moved to `helpText`.

3. **`ux-verificacion-legal`** — the DNI lookup on Verificación de Certificado
   (loading/found/not-found via `useFormSubmission` + `StatusMessage`, button
   stays enabled and relabels during the async check), plus three placeholder
   legal routes (`/privacidad`, `/terminos`, `/reclamaciones`) so the links
   from step 2 resolve to something.

   Open decision: for a mockup with no real backend, default is a short
   honest placeholder body ("Contenido en preparación — texto legal pendiente
   de validación con CICAT Salud") rather than fabricated legal text. Flag if
   you'd rather these point at a "próximamente" state instead of live routes.

4. Any remaining raw hex literals or unlayered shadows get folded into
   whichever of 2/3 touches those files — no longer worth a separate task
   once the tokens from step 1 exist.
