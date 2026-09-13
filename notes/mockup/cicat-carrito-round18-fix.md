# cicat-carrito round 18 fixes

Both gate A and gate B independently converged on the same critical issue with round 17's fix. Verified against source.

## Critical — the purchase record from round 17 isn't scoped to a course

`PurchaseRecord` (`checkout.ts`) stores `nombre`/`correo`/`fileName` but no course id. `CarritoPago` treats *any* existing record as proof the current page's purchase is complete. Failure: buy course A, then navigate to `/carrito/pago?id=courseB` in the same browser session (or click a different "Comprar" button) — `loadPurchaseRecord()` still returns course A's old record, so course B's page immediately renders course A's success confirmation and never lets the user pay for course B at all.

Fix: add a `courseId: string` field to `PurchaseRecord`, populate it from the resolved `course.id` in `handleFinalizarCompra`, and validate it in `isPurchaseRecord` the same way the other fields are checked. In `CarritoPago`, only treat the loaded record as valid for *this* page's purchase if `record.courseId === course.id` — otherwise treat it as if there were no record (fall through to the normal `comprador` guard for a fresh purchase of the current course).

## Real bug — a failed purchase-record write is reported as success

`handleFinalizarCompra` calls `persistPurchaseRecord(record)` and ignores its boolean return value, then unconditionally calls `setPurchaseRecord(record)` and clears the buyer's form data. If the write fails (storage full/unavailable), the UI still shows success and the buyer form is gone — a reload then shows nothing, since the record never actually made it to storage.

Fix: check `persistPurchaseRecord`'s return value. If it returns `false`, don't proceed with the success flow — show a visible error (reuse `fileError` or add a similar inline message) instead of silently confirming a purchase that wasn't actually recorded, and don't clear `CARRITO_DATOS_STORAGE_KEY` in that case (so the buyer's data survives for a retry).

## Not fixing (pre-existing, not a regression from any round in this task)

- The uploaded file itself is never actually transmitted anywhere — only its filename is tracked/persisted. This mockup has no backend and no upload endpoint anywhere in the app; this was true before this task touched these pages and is consistent with every other "form" in the site (the lead-capture form on `CursoDetalle`, `Contacto`'s form, etc., none of which submit anywhere either). Not a defect introduced here.

After fixing: `bun run build`/`lint`/`format:check` clean. Live-verify: complete a purchase for one course, then navigate directly to `/carrito/pago?id=<a-different-course-id>` — it should show that course's normal payment form, not the previous course's success screen.

This really should be the last round now - the remaining scope is narrow and everything else across rounds 9-17 has been fixed and independently verified.
