# cicat-carrito round 9 fixes

Gate A found 14 issues on the final full review; independently verified as real. Fix these:

## Must fix (real bugs)

1. **Whitespace-only input silently breaks checkout** (`src/content/checkout.ts` `isDatosFormComplete`, `src/pages/CarritoDatos.tsx`). HTML `required` accepts a single space, but `isDatosFormComplete` trims and rejects it. A user who types " " in Nombres/Apellidos/DNI/Celular passes native validation, submits, then gets silently bounced back from `/carrito/pago` to `/carrito/datos` with no explanation. Fix by trimming values on change (or on submit) in `CarritoDatos` so what's stored and what's validated agree — the stored value should never contain leading/trailing-only whitespace that `required` would accept but `isDatosFormComplete` rejects.

2. **"Comprar" button on CursoDetalle does nothing** (`src/pages/CursoDetalle.tsx:345`, the `<Button variant="solid">Comprar</Button>`). No `to`, no `onClick` — it's the actual purchase entry point for a real user and it's completely dead. The only working entry into `/carrito/datos` is the header cart icon. Wire it to navigate to `/carrito/datos`. While there, also fix `CarritoDatos.tsx`'s "Volver" link (currently `/cursos-diplomados/detalle` with no id) to preserve the course id so it returns to the actual course being purchased, not always the fallback course — `CursoDetalle.tsx:74-77` already resolves the course from `?id=`, so link with that id.

3. **Unvalidated sessionStorage payload trusted as `DatosFormState`** (`src/content/checkout.ts` `loadStoredDatosForm`). `{ ...INITIAL_DATOS_FORM_STATE, ...JSON.parse(raw) }` is cast to the type with no field validation. A stale or hand-edited key like `{"aceptaPrivacidad":"no"}` makes `isDatosFormComplete` treat it as complete (truthy string) and the checkbox renders checked when consent was never given. Validate each field's type against `INITIAL_DATOS_FORM_STATE`'s shape when loading; fall back to the default for any field that doesn't match.

## Dead code (delete)

4. `src/components/PagePlaceholder.tsx` — orphaned. It was only used by the old `CarritoDatos`/`CarritoPago` stubs this diff replaced. `grep -rn PagePlaceholder src` now matches only its own definition. Delete the file.
5. `public/assets/carrito/67d7c7d8-f278-407a-b6b6-24c566401545.jpg` — referenced nowhere in `src`. Delete it.
6. `src/pages/CarritoPago.tsx` lines ~113, 126 — `compradorNombre ? ... : ""` and `comprador.correo ? ... : ""` are dead-false branches: by the time this renders, `isDatosFormComplete` already guaranteed both are non-blank. Inline the values directly, drop the ternaries.
7. `src/content/checkout.ts` — `INITIAL_DATOS_FORM_STATE` is exported but used only inside its own module. Drop the `export`.

## Real duplication

8. **`courseInvestment` in `CarritoDatos.tsx` (lines ~18-21) reconstructs a string that already exists and doesn't match it.** The composed string uses `course.pricing.modulesLabel` ("7 módulos × S/ 180") while `course.investment` (the canonical field, `courses.ts:93`) says "7 módulos de S/ 180" — they've already drifted. Just use `course.investment` directly; delete the reconstruction.
9. **"Volver" pill is duplicated verbatim** between `CarritoDatos.tsx` (~lines 232-243) and `CarritoPago.tsx` (~lines 221-232) — same markup, same `ICON_ARROW_VOLVER` constant defined twice. Extract one shared component, the same way `CarritoHero`/`InscripcionStepper` were already extracted for this exact reason.

## Structure

10. **Purchase-completion cleanup routed through a `useEffect` instead of the click handler** (`CarritoPago.tsx` ~lines 37-44). `setPurchaseComplete(true)` fires in the "Finalizar compra" click handler; a separate `useEffect` keyed on `purchaseComplete` then clears sessionStorage. Move the `sessionStorage.removeItem(...)` call directly into the click handler and delete the effect — it's a direct consequence of that click, not of a render.

## Explicitly out of scope (do not touch, already decided in prior rounds)

- The 4th copy of the Ciudad/Profesión option arrays (cosmetic duplication nit).
- `aria-live="polite"` timing on the conditionally-mounted filename paragraph (cosmetic accessibility nit).
- The no-op `<a href="#">Ver aquí</a>` privacy-policy links — matches an existing pre-diff pattern elsewhere in the mockup (no backend wired anywhere), not a new regression from this diff.
- Unifying `DatosFormState` and `CursoDetalle`'s `INITIAL_LEAD_FORM` shape — these are two different domain concepts (a purchase/checkout form vs. a lead-capture contact form) that happen to collect similar-shaped fields; not real duplication.

After fixing: run `bun run build`, `bun run lint`, `bun run format:check`, and re-verify the full purchase flow live (Comprar -> Datos -> Pago -> success) plus the whitespace-only-input case and a stale/malformed sessionStorage payload case. This must be the last round — confirm each item above is actually done before reporting.
