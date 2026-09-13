# cicat-carrito round 19 fix

Gate B found one real issue with round 18's course-scoping fix; verified against source.

## Real bug — a stale completed-purchase record permanently blocks retrying the same course

`CarritoPago` treats any stored `PurchaseRecord` whose `courseId` matches the current course as proof this purchase is done, and always renders the success screen for it — there's no way to clear it. Once a user completes a purchase for course X, `CarritoDatos.tsx`'s `handleSubmit` never touches `CARRITO_PURCHASE_STORAGE_KEY`, so going through the Datos form again for course X (a deliberate retry, or simply clicking "Comprar" on that course again) always lands back on the *old* success screen instead of a fresh payment form, no matter what new data is entered.

Fix: in `CarritoDatos.tsx`'s `handleSubmit`, right before navigating to `/carrito/pago`, clear any existing `CARRITO_PURCHASE_STORAGE_KEY` record (a plain `sessionStorage.removeItem` is fine, wrapped in the same try/catch style already used elsewhere in this file — no need for a new helper unless one already fits). Submitting the Datos form is always the user declaring intent to start (or restart) a purchase, so any prior completion record should be superseded at that point.

## Not fixing (raised again this round, same reasoning as before, final)

- The uploaded file is never actually transmitted anywhere (only its filename is tracked) — this mockup has no backend or upload endpoint anywhere in the app; pre-existing, not a regression from this task.
- The no-op `<a href="#">Ver aquí</a>` privacy-policy links — matches an existing pre-diff pattern elsewhere in the mockup.
- "Datos protegidos y encriptados" next to the padlock icon is standard trust-badge copy (the same genre as an "SSL secured" badge on a real checkout page), not a literal technical claim about how sessionStorage is implemented. It's original Figma-derived copy, not something introduced by this task, and this is a demo mockup with no real payment processing behind it either way. Not treating this as a code defect.

After fixing: `bun run build`/`lint`/`format:check` clean. Live-verify: complete a purchase for a course, then go back to that same course's Datos page, fill the form again, and submit — it should reach a fresh payment form for that course, not the old success screen.
