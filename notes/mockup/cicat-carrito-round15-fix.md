# cicat-carrito round 15 fixes

Gate B PASSed; gate A found 5 issues plus 3 minor ones. Verified against source. Fix these.

Ownership has been widened - state/tasks/cicat-carrito/owns now also includes src/components/Header.tsx, src/pages/Home.tsx, and src/pages/Contacto.tsx.

## Real bugs

1. **Header cart icon fabricates a purchase for a course the user never chose.** `Header.tsx:63` (desktop) and `:118` (mobile) both link straight to `/carrito/datos` with no `id`. `resolveCourseSelection(null)` silently returns the default course with `notFound: false` (correct for a *browsing* context like `CursoDetalle`'s bare `/detalle` route, wrong for *checkout*) — a user who clicks the cart icon from any page, having never selected anything, is walked through paying S/ 1,410 for "Auditoría en Salud" with zero indication it was auto-selected. Fix: point both Header cart links at `/cursos-diplomados` (the course catalog) instead of `/carrito/datos`. The cart icon becomes "go pick something to buy" rather than a direct-to-checkout shortcut with no product context — course-specific "Comprar" buttons already correctly carry `?id=`.

2. **Step 2's icon is invisible exactly when it's active.** `InscripcionStepper.tsx`'s `ICON_PAGO` (`public/assets/carrito/c9131772-e93f-4bab-a92c-edaaf064851c.svg`) draws every path with `stroke="#143769"` — the identical color as the active-state circle background (`bg-[#143769]`). On `/carrito/pago`, the active step renders as a plain dark disc with no visible icon. Compare `ICON_CARRITO` (step 1), which correctly uses `stroke="white"` for exactly this reason. Fix: edit `c9131772-e93f-4bab-a92c-edaaf064851c.svg` directly, changing all four `stroke="#143769"` to `stroke="white"` to match the sibling icon's own convention.

3. **File picker's `accept` only lists MIME types, so files with no MIME mapping (the exact case `ALLOWED_FILE_EXTENSIONS` exists for) never appear in the OS file dialog by default.** `CarritoPago.tsx`'s `accept={ALLOWED_FILE_TYPES.join(",")}` excludes extensions; a user would have to manually switch their file picker to "All files" to ever reach the extension-fallback branch in `isAllowedFile`. Add the extensions to the `accept` string too: `` accept={[...ALLOWED_FILE_TYPES, ...ALLOWED_FILE_EXTENSIONS].join(",")} ``.

4. **`CIUDAD_OPTIONS`/`PROFESION_OPTIONS` are still inlined in `Home.tsx` (~lines 556, 562) and `Contacto.tsx` (~lines 81, 87), and this is no longer just cosmetic.** `isValidFieldValue` in `checkout.ts` whitelists restored `ciudad`/`profesion` values against `checkout.ts`'s copy of these lists. If Home's or Contacto's inline copies ever drift (e.g. a city added to one but not the others), a value a user legitimately picked in one of those forms would fail validation elsewhere and silently reset to `""`. Import `CIUDAD_OPTIONS`/`PROFESION_OPTIONS` from `../content/checkout` in both `Home.tsx` and `Contacto.tsx` and delete the inline arrays.

## Minor (cheap, include them)

5. `CursoDetalle.tsx:337`'s "Comprar" link (`` `/carrito/datos?id=${course.id}` ``) is missing `encodeURIComponent`, while every other course-id interpolation in the flow (`CarritoDatos`, `CarritoPago`) already encodes it. Add it for consistency, even though course ids are currently plain slugs.
6. `CarritoDatos.tsx:223`'s course thumbnail has `alt={courseTitle}`, duplicating the adjacent `<p>{courseTitle}</p>` — a screen reader announces the title twice. Change to `alt=""` since the image is decorative next to visible text.

## Still explicitly out of scope — final decision, third time this has come up, stop re-flagging

- **Reloading the confirmation screen discards the purchase state** (`CarritoPago.tsx`). Real, but this is a client-only demo with no backend and no real payment to lose — not fixing it.

After fixing: `bun run build`/`lint`/`format:check` clean. Live-verify: the header cart icon goes to the course catalog, not straight into checkout; the Pago step's icon is visible (not a blank dark circle); the file picker actually offers non-MIME-mapped files of the allowed extensions.
