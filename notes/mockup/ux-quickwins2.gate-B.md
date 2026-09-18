# Gate B: ux-quickwins2

luna reviewed the changes since 69476ef5252e, with HEAD at 69476ef5252e (fingerprint a965288409c1). Verdict: FAIL.

## Findings

- [major, confirmed] `src/pages/Home.tsx:216` A valid submission only sets local success state; no request, persistence, or other submission boundary sends the lead anywhere, so the UI confirms receipt while the user's data is lost. (finding a6bbd431)
- [major, confirmed] `src/pages/Contacto.tsx:65` A valid submission only sets local success state; no request, persistence, or other submission boundary sends the lead anywhere, so the UI confirms receipt while the user's data is lost. (finding 018b69f5)

## Checked

- `src/components/ContactInfoItem.tsx`: Verified email and phone-shaped contact lines render as mailto and tel links with separators removed from phone hrefs.
- `src/components/Footer.tsx`: Verified each legal item renders as a React Router link.
- `src/components/Header.tsx`: Verified the header email mailto link and mobile-menu ARIA/Escape handling compile successfully.
- `src/content/footer.ts`: Verified legal-link paths match routes defined in src/router.tsx.
- `src/pages/Contacto.tsx`: Verified controlled fields, select options, custom DNI/celular validation, privacy links, and error rendering compile successfully.
- `src/pages/Home.tsx`: Verified controlled fields, select options, custom DNI/celular validation, privacy links, and error rendering compile successfully.
- `src/content/leadForm.ts`: Verified the valid DNI, celular, and complete-form smoke test passed.

## Reviewer's report

Findings:

- Major — `src/pages/Home.tsx:216`: A valid form only sets local success state; no request, persistence, or submission boundary exists. Users see “Hemos recibido tu solicitud,” but the lead is lost.
- Major — `src/pages/Contacto.tsx:65`: Same false-success behavior: valid data is never sent or stored, yet the UI confirms receipt.

Verified working:

- `ContactInfoItem.tsx`: Email and phone lines generate correct `mailto:`/`tel:` links.
- `Footer.tsx` / `footer.ts`: Legal links map to existing routes.
- `Header.tsx`: Mail link, menu ARIA attributes, and Escape handling compile correctly.
- `Contacto.tsx` / `Home.tsx`: Controlled fields, selects, custom DNI/celular validation, privacy links, and error rendering compile.
- `leadForm.ts`: Valid DNI, celular, and complete-form smoke test passed.
- `bun run build`, `bun run lint`, `bun run format:check`, and `git diff --check` passed. No browser executable was available for visual interaction checks.
