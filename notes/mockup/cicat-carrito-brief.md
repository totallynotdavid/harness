# Convert CarritoDatos + CarritoPago to the established responsive pattern

`mockup`'s foundation task (`cicat-web`, already landed) set the pattern this
follows: bun + TS + oxlint/oxfmt, Tailwind v4, react-router v7, ten real
routes wired in `src/router.tsx`. `src/pages/Home.tsx` and
`src/pages/Contacto.tsx` are the two fully-converted reference pages — read
both before writing anything, especially `Contacto.tsx` for the form pattern
(`FormField`/`SelectField`, `required` genuinely forwarded to the DOM
element, not just a cosmetic asterisk).

`src/pages/CarritoDatos.tsx` (route `/carrito/datos`) and
`src/pages/CarritoPago.tsx` (route `/carrito/pago`) currently render
`PagePlaceholder`. These are the two steps of one checkout flow — replace
both with real pages, and make sure the step from Datos to Pago actually
navigates (a real `Link`/`Button to="/carrito/pago"` on the datos page's
continue action, not `href="#"`).

## Source

Figma file "Mock", fileKey `wetbbJa7crTH0ZqbtVPpur`. Each step has a
separate desktop and mobile frame in Figma — merge each pair into one
responsive component, same as the foundation task did for Home/Contacto:
- `1:3656` — "Completar tus datos" (Desktop) → merge with:
- `1:4216` — "Completar tus datos" (Mobile) → into `CarritoDatos.tsx`
- `1:3961` — "Pago" (Desktop) → merge with:
- `1:4510` — "Pago" (Mobile) → into `CarritoPago.tsx`

Load the `figma-design-to-code` skill, then `get_design_context` on each
node (split into sections if too large). Download real assets into your own
subfolder — `public/assets/carrito/<figma-uuid>.<ext>` — not the flat
`public/assets/` root. This task runs in parallel with four siblings
converting other pages; Captain's worktree-ownership guard treats
`public/assets/*` as one claim, so each task gets its own subdirectory to
avoid a false collision. Reference files by their `/assets/carrito/...`
path; existing assets in `public/assets/` are fine to reference read-only,
just don't add new files there.

For copy/content not obvious from Figma text, the old desktop/mobile port is
in git history: `git show f5c02c8:src/pages/CheckoutDatosDesktop.jsx`,
`CheckoutDatosMobile.jsx`, `CheckoutPagoDesktop.jsx`,
`CheckoutPagoMobile.jsx` — reference only for wording and form-field list,
never for layout technique (that's exactly what merging into one responsive
component replaces).

## Rules (same as Home/Contacto, not re-derived)

- One responsive component per step, Tailwind breakpoints, normal document
  flow — no `absolute`-pixel Figma-frame positioning, no spacer divs.
- Semantic landmarks and heading hierarchy.
- Every required form field uses `FormField`/`SelectField` with `required`
  genuinely wired to the DOM element — that was a real gate-review defect on
  the foundation task, don't repeat it.
- The Datos → Pago transition is a real navigation (`Link`/`Button to=`),
  never `href="#"`.
- Reuse existing components (`Button`, `FormField`, `SelectField`,
  `SectionHeading`, `Breadcrumb`) before inventing new ones.
- `src/router.tsx` already has both routes wired — don't edit it unless
  adding a genuinely new sub-route.

## Verification

`bun run build`, `bun run lint`, `bun run format:check` all clean. Drive a
real dev server and check both steps at desktop and mobile widths with zero
console errors (Playwright is fine if there's no display), including
clicking through Datos → Pago. Compare against `get_screenshot` for all four
source frames.

## Deliverable

`src/pages/CarritoDatos.tsx` and `src/pages/CarritoPago.tsx` fully
converted, no longer using `PagePlaceholder`, verified live and navigable
end to end. Leave changes uncommitted — Captain reviews and lands.
