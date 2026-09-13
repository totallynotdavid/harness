# cicat-carrito round 11 fixes

Both gate A and gate B independently found the same critical issue. Verified all of the below against source. Fix these:

## Critical (financial correctness — must fix)

1. **Checkout ignores the selected course and always shows/charges for "Auditoría en Salud".** `src/pages/CarritoDatos.tsx:18` and `src/pages/CarritoPago.tsx:17` both do `const course = getCourseById("auditoria-salud")!` at module scope — a constant, not derived from anything. `CarritoDatos` reads `searchParams.get("id")` (line 32) but only uses it to build the "Volver" href; the actual course used for the image/title/price shown to the buyer, and the "Monto a pagar" on the payment step, never consults it. Since `CursoDetalle`'s "Comprar" button now links to `/carrito/datos?id=<real-id>` (round 9), a user buying any of the other 11 courses in `src/content/courses.ts` sees and is told to pay for the wrong course, at the wrong price (most show S/ 1,410 when the real course might be S/ 330, S/ 350, S/ 449, etc).

   Fix: in both `CarritoDatos.tsx` and `CarritoPago.tsx`, resolve `course` inside the component from `searchParams.get("id")` via `getCourseById`, falling back to `auditoria-salud` (or the catalog's first entry) when the id is missing or unknown. `CarritoPago` has no search param today — carry the id forward from `CarritoDatos` (e.g. append it to the `navigate("/carrito/pago")` call as `?id=...`, and read it the same way on `CarritoPago`). Also update both "Volver" (`VolverLink`) usages so the id keeps flowing through the whole Detalle -> Datos -> Pago -> back loop, not just the one hop it currently covers.

## Real bugs

2. **Invalid submit is a silent dead end.** `CarritoDatos.tsx` `handleSubmit`: after trimming, `if (!isDatosFormComplete(trimmedForm)) return;` — there is no error state anywhere in the component. A user who types a single space into "Nombres" watches the field empty itself (the trim writes back) and the page simply does not navigate, with zero explanation. Add a visible inline error message when `isDatosFormComplete` fails after trim (e.g. "Completa todos los campos requeridos").

3. **`REQUIRED_TEXT_FIELDS` (`src/content/checkout.ts:56`) is typed as `(keyof DatosFormState)[]`**, which admits the three boolean keys (`residenteExtranjero`, `aceptaPrivacidad`, `aceptaComunicaciones`). The `String(form[field]).trim() !== ""` check on line 68 only works by coercion because of this over-wide type — narrow the array's type to just the string-valued keys of `DatosFormState` so a boolean key can't silently be added to it later and pass unconditionally (`String(false)` is `"false"`, never empty).

4. **Dead ternary — `CarritoPago.tsx:112`.** `{fileName ? \` (${fileName})\` : ""}` is unreachable-false: the "Finalizar compra" button that leads to this success copy only renders inside `{fileName && ...}` (line 195), so `fileName` is always non-null here. Inline it: `` (${fileName})``.

## Nit (cheap, include it)

5. `CarritoPago.tsx:83` — "Elije tu billetera digital" should be "Elige" (correct Spanish imperative).

## Still explicitly out of scope (unchanged from prior rounds)

- The 4th copy of the Ciudad/Profesión option arrays.
- `aria-live="polite"` timing on the conditionally-mounted filename paragraph.
- The no-op `<a href="#">Ver aquí</a>` privacy-policy links.
- Unifying `DatosFormState` and `CursoDetalle`'s `INITIAL_LEAD_FORM` shape.
- `InscripcionStepper`'s "Detalle" label vs. the page heading "Completa tus datos" (cosmetic naming nit, not a functional bug).

After fixing: `bun run build`/`lint`/`format:check` clean, then live-verify the full flow for at least two different courses (not just auditoria-salud) end to end: Detalle(id=X) -> Comprar -> Datos shows course X's price/title/image -> Pago shows course X's amount -> Volver at each step returns to course X, not the fallback. Also re-verify the whitespace-only-input case now shows a visible error instead of silently failing.
