# Convert the Nosotros page to the established responsive pattern

`mockup`'s foundation task (`cicat-web`, already landed) set the pattern this
follows: bun + TS + oxlint/oxfmt, Tailwind v4, react-router v7, ten real
routes wired in `src/router.tsx`. `src/pages/Home.tsx` and
`src/pages/Contacto.tsx` are the two fully-converted reference pages — read
both before writing anything. `src/pages/Nosotros.tsx` currently renders
`PagePlaceholder` ("not yet migrated"); replace it with the real page.

## Source

Figma file "Mock", fileKey `wetbbJa7crTH0ZqbtVPpur`, frame `1:1028`
("Nosotros"). Load the `figma-design-to-code` skill, then `get_design_context`
on that node (split into sections if it's too large — same recovery the
foundation task used). Download real assets the same way Home/Contacto did,
but into your own subfolder — `public/assets/nosotros/<figma-uuid>.<ext>` —
not the flat `public/assets/` root. This task runs in parallel with four
siblings converting other pages; Captain's worktree-ownership guard treats
`public/assets/*` as one claim, so each task gets its own subdirectory to
avoid a false collision. Reference the files by their `/assets/nosotros/...`
path; existing assets already in `public/assets/` (used by Home/Contacto)
are fine to reference read-only, just don't add new files there.

For copy/content that isn't obvious from the Figma text nodes, the old
absolute-positioned port is still in git history if you need it:
`git show f5c02c8:src/pages/Nosotros.jsx` and
`git show f5c02c8:src/pages/NosotrosMobile.jsx` — reference only for wording,
never for layout technique (that's exactly what this migration replaces).

## Rules (same as Home/Contacto, not re-derived)

- One responsive component, Tailwind breakpoints, normal document flow — no
  `absolute`-pixel Figma-frame positioning, no spacer-height divs.
- Semantic landmarks and heading hierarchy.
- Every link/button that should navigate uses a real react-router `Link`/
  `Button to=`, never `href="#"`.
- Reuse existing components from `src/components/` (`Button`, `FormField`,
  `SelectField`, `SectionHeading`, `Breadcrumb`, `ContactInfoItem`,
  `SocialLinks`, `TestimonialCard`, `FaqAccordion`) before inventing new
  ones. If Nosotros needs something genuinely new, add it there with a
  distinct name.
- Centralize any new copy/data under `src/content/` if it's the kind of
  thing that repeats (team members, stats, values) — follow the shape of
  `src/content/contact.ts`.
- `src/router.tsx` already has this route wired (`/nosotros` → `Nosotros`) —
  don't edit it unless you're adding a genuinely new sub-route.

## Verification

`bun run build`, `bun run lint`, `bun run format:check` all clean. Drive a
real dev server (`bun run dev`) and check the page at desktop and mobile
widths with zero console errors — a headless browser (Playwright, already
used by the foundation task) is fine if there's no display available.
Compare against `get_screenshot` for visual fidelity.

## Deliverable

`src/pages/Nosotros.tsx` fully converted, no longer using `PagePlaceholder`,
verified live. Leave changes uncommitted — Captain reviews and lands.
