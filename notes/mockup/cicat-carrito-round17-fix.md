# cicat-carrito round 17 fixes

Gate A has now independently raised these same two issues across 4 separate rounds (13, 14, 15, and this one, where it rates both P1). Given the recurrence and severity, fixing both now rather than deferring again.

## 1. Storage-write failure leaves checkout in a silent, unrecoverable loop

`persistDatosForm` (`checkout.ts`) swallows `sessionStorage.setItem` failures in a try/catch with no return signal. `CarritoDatos`'s `handleSubmit` calls it and unconditionally navigates to `/carrito/pago` right after. `CarritoPago` requires that same storage as its only source of buyer data (`loadStoredDatosForm` + `isDatosFormComplete`) — if the write failed, `comprador` is `null` there and the guard immediately bounces back to `/carrito/datos`, with the just-filled form now gone. The user can never get past step 1, with zero explanation.

Fix: make `persistDatosForm` return a `boolean` (`true` on success, `false` if the `try` block threw). In `CarritoDatos.tsx`'s `handleSubmit`, check the return value: if `false`, call `setSubmitError(...)` with a message like "No se pudo guardar tu información. Verifica la configuración de tu navegador e inténtalo de nuevo." and do not navigate. Reuse the existing `submitError` state and its rendering — this is the same mechanism round 11 already added for the whitespace-validation case.

## 2. Reloading the success screen loses the confirmation and looks like the purchase never happened

`handleFinalizarCompra` (`CarritoPago.tsx`) sets `purchaseComplete` as component-only React state and immediately clears `CARRITO_DATOS_STORAGE_KEY`. `comprador` is captured once at mount from that same storage. A refresh (or Back-then-Forward) after completing a purchase remounts the component with nothing in storage, `comprador` is `null`, and the guard redirects to `/carrito/datos` with a blank form — the confirmation, the buyer's name, and the uploaded receipt filename are all gone with no trace anything succeeded.

Fix: when the purchase completes, persist a small "purchase confirmed" record to sessionStorage under its own key (e.g. `CARRITO_PURCHASE_STORAGE_KEY` in `checkout.ts`, holding at minimum the buyer's name/email and the receipt filename) instead of only holding it in React state, and don't clear it. On mount, check for this record before checking `comprador`/`isDatosFormComplete`: if present, render the success view directly from it (skip the guard entirely). This way reloading `/carrito/pago` after a completed purchase re-shows the confirmation instead of bouncing to a blank form. The existing `CARRITO_DATOS_STORAGE_KEY` can still be cleared on completion as before, since it's superseded by the new purchase record.

After fixing: `bun run build`/`lint`/`format:check` clean. Live-verify: (a) temporarily make `sessionStorage.setItem` throw (e.g. via devtools override or a quick local test) and confirm `CarritoDatos` shows a visible error instead of silently redirecting; (b) complete a purchase on `/carrito/pago`, then reload the page — the success confirmation should still show, not a blank Datos form.

This should be the last round. Everything else previously flagged across rounds 9-16 has been fixed and independently verified.
