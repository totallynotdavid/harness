# Convert VerificacionCertificado to the established responsive pattern

`mockup`'s foundation task (`cicat-web`, already landed) set the pattern this
follows: bun + TS + oxlint/oxfmt, Tailwind v4, react-router v7, ten real
routes wired in `src/router.tsx`. `src/pages/Home.tsx` and
`src/pages/Contacto.tsx` are the two fully-converted reference pages — read
both before writing anything, especially `Contacto.tsx` for the form-field
pattern (`FormField`/`SelectField` from `src/components/FormField.tsx`,
`required` genuinely forwarded to the DOM element, not just cosmetic).
`src/pages/VerificacionCertificado.tsx` currently renders `PagePlaceholder`;
replace it with the real page — a certificate-verification form/lookup.

## Source

Figma file "Mock", fileKey `wetbbJa7crTH0ZqbtVPpur`, frame `1:2089`
("Verificación de certificado"). Load the `figma-design-to-code` skill, then
`get_design_context` on that node (split into sections if too large).
Download real assets into your own subfolder —
`public/assets/verificacion/<figma-uuid>.<ext>` — not the flat
`public/assets/` root. This task runs in parallel with four siblings
converting other pages; Captain's worktree-ownership guard treats
`public/assets/*` as one claim, so each task gets its own subdirectory to
avoid a false collision. Reference files by their
`/assets/verificacion/...` path; existing assets in `public/assets/` are
fine to reference read-only, just don't add new files there.

For copy/content not obvious from Figma text, the old port is in git
history: `git show f5c02c8:src/pages/VerificacionCertificado.jsx` and
`VerificacionCertificadoMobile.jsx` — reference only for wording, not layout
technique.

## Rules (same as Home/Contacto, not re-derived)

- One responsive component, Tailwind breakpoints, normal document flow — no
  `absolute`-pixel Figma-frame positioning, no spacer divs.
- Semantic landmarks and heading hierarchy.
- If this page has a form (a certificate-code lookup), every required field
  uses `FormField`/`SelectField` with `required` genuinely wired, not just a
  visual asterisk — that was a real gate-review defect on the foundation
  task, don't repeat it.
- Reuse existing components before inventing new ones.
- `src/router.tsx` already has this route wired
  (`/verificacion-certificado` → `VerificacionCertificado`) — don't edit it
  unless adding a genuinely new sub-route.

## Verification

`bun run build`, `bun run lint`, `bun run format:check` all clean. Drive a
real dev server and check the page at desktop and mobile widths with zero
console errors (Playwright is fine if there's no display). Compare against
`get_screenshot` for visual fidelity.

## Deliverable

`src/pages/VerificacionCertificado.tsx` fully converted, no longer using
`PagePlaceholder`, verified live. Leave changes uncommitted — Captain
reviews and lands.
