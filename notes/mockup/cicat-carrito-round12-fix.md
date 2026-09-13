# cicat-carrito round 12 fixes

Both gate A and gate B independently found the same critical regression in round 11's fix. Verified all of the below against source.

## Critical — undoes the round-11 fix under exactly the condition it exists for

1. **`CarritoPago.tsx`'s `<Navigate>` guard hardcodes `/carrito/datos`, dropping the id it just computed.** `datosHref` (line ~26) correctly preserves `?id=` and is used by `VolverLink`, but the early-return guard a few lines below it does `return <Navigate to="/carrito/datos" replace />;` instead of `return <Navigate to={datosHref} replace />;`. Anyone who lands on `/carrito/pago?id=X` with no valid stored form (fresh tab, cleared storage, bookmarked/shared link, or a refresh right after `handleFinalizarCompra` clears sessionStorage) gets bounced to `/carrito/datos` with the id stripped, `resolveCartCourse(null)` silently substitutes the default course, and the user proceeds to pay for a course they never selected. One-line fix: use `datosHref` in that `Navigate`.

## Real bugs

2. **`resolveCartCourse` (`src/content/checkout.ts`) collapses two different cases `getCourseById` is documented to keep separate.** `courses.ts`'s own doc comment says: "a present-but-unmatched id returns `undefined` so the caller can show an explicit not-found state instead of silently substituting a different course." `resolveCartCourse` falls back to the default course for *any* falsy result, so `/carrito/datos?id=curso-retirado` (a stale/renamed id) silently shows the Auditoría course with no warning, while `CursoDetalle` for the identical id shows "Curso no encontrado." Only default silently when `courseId` itself is null/absent; when an id was given but `getCourseById` returns `undefined`, surface an explicit not-found state (mirror whatever `CursoDetalle` already does for this case) instead of substituting.

3. **File-picker `accept` attribute is a hand-copied duplicate of `ALLOWED_FILE_TYPES`** (`CarritoPago.tsx` line 18 vs the literal string at line ~178). Use `accept={ALLOWED_FILE_TYPES.join(",")}` so there's one source of truth.

4. **File-type check rejects files with an empty `file.type`.** `ALLOWED_FILE_TYPES.includes(file.type)` fails closed when the browser can't map the file to a MIME type (happens for some PDFs/images depending on OS file-association state), rejecting a valid file with "Formato no permitido" and no way to proceed. When `file.type` is empty, fall back to checking the filename extension (.jpg/.jpeg/.png/.webp/.pdf) against the allowed set.

5. **`CIUDAD_OPTIONS`/`PROFESION_OPTIONS` are still duplicated** between `CarritoDatos.tsx` and `CursoDetalle.tsx` (identical inline arrays there). Move both into `src/content/checkout.ts` next to `DatosFormState` and import from both pages. This is the third round flagging this — fix it now.

6. **`aria-live="polite"` on the conditionally-mounted "Archivo seleccionado" text** (`CarritoPago.tsx` ~line 198) mounts in the same render as its content, so most screen readers never announce it — same issue as the adjacent `fileError`, which correctly uses `role="alert"` (announced on insertion). This is also its third round flagged. Either switch it to `role="alert"` to match, or render the region unconditionally and vary only its text content. Fix it now.

7. **Both checkout pages lost their breadcrumb.** The old `PagePlaceholder` stub rendered `Inicio › Carrito › Datos|Pago`; `CarritoHero` has no equivalent, and every other page in the app (`Contacto.tsx` etc.) still renders `<Breadcrumb>`. Add `<Breadcrumb items={[{ label: "Inicio", to: "/" }, { label: "Carrito" }, { label: "Datos" | "Pago" }]} />` (matching the existing `Breadcrumb` component's API — check `Breadcrumb.tsx`/an existing usage for the exact prop shape) to both `CarritoDatos.tsx` and `CarritoPago.tsx`.

## Still explicitly out of scope — final decision, stop re-flagging

- **Unifying `DatosFormState` and `CursoDetalle`'s `INITIAL_LEAD_FORM` shape.** These are two different domain concepts — a purchase/checkout form vs. a marketing lead-capture form — that happen to collect similarly-shaped fields. Merging them because the shapes overlap would couple two flows that should be free to diverge (e.g. checkout may need billing fields a lead form never will). Not fixing this.
- The no-op `<a href="#">Ver aquí</a>` privacy-policy links — matches an existing pre-diff pattern elsewhere in the mockup.
- `InscripcionStepper`'s "Detalle" label vs. the page heading "Completa tus datos" — cosmetic naming nit, not a functional bug.

After fixing: `bun run build`/`lint`/`format:check` clean. Live-verify: (a) opening `/carrito/pago?id=<some-other-course-id>` directly with no sessionStorage redirects to `/carrito/datos?id=<same-id>`, not the bare path; (b) an unknown course id shows a not-found state consistent with `CursoDetalle`'s; (c) both checkout pages show a breadcrumb like every other page.
