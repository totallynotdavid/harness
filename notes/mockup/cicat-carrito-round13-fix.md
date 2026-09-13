# cicat-carrito round 13 fixes

Gate B PASSed with only a minor note; gate A found 8 issues. Verified the following against source. Fix these:

## Real bugs

1. **Duplicate unlabeled price line for 11 of the 12 courses.** `CarritoDatos.tsx:243` renders `{course.investment}` as a bare line, then the divider, then "Total a invertir" with `{courseTotal}`. Only `auditoria-salud` has a `pricing` breakdown that makes `investment` a real cost sentence; every other course in `courses.ts` has `investment` byte-identical to `price`. Buying any other course shows the same number twice, the first copy with no label. Only render the `course.investment` line when it differs from `courseTotal` (i.e. when `course.pricing` exists / when `course.investment !== courseTotal`); otherwise skip straight to the "Total a invertir" row.

2. **`resolveCartCourse` (`checkout.ts`) re-implements a default `getCourseById` already provides, via an unenforced second source of truth and a non-null assertion.** `getCourseById` is overloaded so `getCourseById(undefined)` returns a non-optional `Course` (its own doc comment: "a missing id ... silently defaults to the first course"). Replace `DEFAULT_CART_COURSE_ID`/`getCourseById(DEFAULT_CART_COURSE_ID)!` with `getCourseById(undefined)` — removes the second hardcoded id and the `!` in one move, and stops a future reorder/rename of `COURSES` from silently producing a runtime crash (`course` becoming `undefined`, then `course.badge` throwing).

3. **Course id is spliced into URLs unencoded — 4 sites.** `CarritoDatos.tsx:31` (volverHref), `:77` (navigate to pago), `CarritoPago.tsx:35` (datosHref) all do `` `...?id=${courseIdParam}` `` directly. A course id containing `#` or `&` (unlikely today, but `courseIdParam` is arbitrary user-supplied URL content) corrupts the query string and desyncs which course each step resolves. Wrap all four with `encodeURIComponent(courseIdParam)`.

4. **Storage read and write live in different files.** `checkout.ts` owns `CARRITO_DATOS_STORAGE_KEY`, `DatosFormState`, and the validating reader `loadStoredDatosForm`, but the matching `JSON.stringify`/`setItem` pair is written directly in `CarritoDatos.tsx` (the persist-on-change effect and the submit handler). Add a `persistDatosForm(form: DatosFormState): void` in `checkout.ts` that does the try/setItem/catch, and call it from both places in `CarritoDatos.tsx` instead of duplicating the try/catch.

5. **Not-found banner duplicated verbatim** between `CarritoDatos.tsx` (~lines 86-95) and `CarritoPago.tsx` (~lines 88-97) — identical markup, class string, and copy. These two pages already share `CarritoHero`/`InscripcionStepper`/`VolverLink` for exactly this reason. Extract a small shared component (e.g. `src/components/CourseNotFoundBanner.tsx`) and use it in both.

6. **`role="alert"` on a routine, non-urgent status line.** `CarritoPago.tsx` — "Archivo seleccionado: {fileName}" is a success confirmation, not an alert; `role="alert"` interrupts screen readers as if something urgent happened. Change it to `role="status"` (the adjacent format/size error correctly keeps `role="alert"`, since that one is genuinely urgent). While there: the hidden `<input type="file" className="hidden">` (~line 197) has no accessible name — add `aria-label="Comprobante de pago"` (or similar) so it isn't announced as an unnamed control if a screen-reader user tabs to it directly.

## Explicitly out of scope this round (narrow edge cases, do not chase further)

- sessionStorage write failures (private-mode/blocked-storage) and reload-destroys-confirmation-screen are both real but narrow edge cases in what is a client-only demo with no backend — not fixing either this round.

After fixing: `bun run build`/`lint`/`format:check` clean. Live-verify: buying a course other than `auditoria-salud` shows only one price line, not two; a course id round-trips correctly through the flow; `role="status"` announces politely rather than interrupting (check via devtools accessibility tree if a screen reader isn't available).
