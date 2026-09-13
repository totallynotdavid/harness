# Convert CursosDiplomados + CursoDetalle to the established responsive pattern

`mockup`'s foundation task (`cicat-web`, already landed) set the pattern this
follows: bun + TS + oxlint/oxfmt, Tailwind v4, react-router v7, ten real
routes wired in `src/router.tsx`. `src/pages/Home.tsx` and
`src/pages/Contacto.tsx` are the two fully-converted reference pages — read
both first. `src/components/CourseCard.tsx` already exists (used on Home,
links to `/cursos-diplomados/detalle`) — this task's catalog page is where
it's meant to actually be used at scale, so build the catalog around it
rather than duplicating its markup.

`src/pages/CursosDiplomados.tsx` (catalog, route `/cursos-diplomados`) and
`src/pages/CursoDetalle.tsx` (detail, route `/cursos-diplomados/detalle`)
currently render `PagePlaceholder`. Replace both with real pages.

## Source

Figma file "Mock", fileKey `wetbbJa7crTH0ZqbtVPpur`:
- `1:1490` — "Curso/diplomados" (the catalog page)
- `1:3199` — "Detalle del curso" (the detail page)

Load the `figma-design-to-code` skill, then `get_design_context` on each node
(split into sections if too large). Download real assets into your own
subfolder — `public/assets/cursos/<figma-uuid>.<ext>` — not the flat
`public/assets/` root. This task runs in parallel with four siblings
converting other pages; Captain's worktree-ownership guard treats
`public/assets/*` as one claim, so each task gets its own subdirectory to
avoid a false collision. Reference files by their `/assets/cursos/...` path;
existing assets in `public/assets/` (used by Home/Contacto, including the
ones `CourseCard` already references) are fine to reference read-only, just
don't add new files there.

For copy/content not obvious from Figma text, the old port is in git
history: `git show f5c02c8:src/pages/CursosDiplomados.jsx`,
`CursosDiplomadosMobile.jsx`, `CursoDetalle.jsx`, `CursoDetalleMobile.jsx` —
reference only for wording, not layout technique.

`/cursos-diplomados/detalle` is a static stand-in route (no CMS/data layer
yet, same as the foundation task left it) — don't build dynamic `:slug`
routing for content that doesn't exist yet.

## Rules (same as Home/Contacto, not re-derived)

- One responsive component per page, Tailwind breakpoints, normal document
  flow — no `absolute`-pixel Figma-frame positioning, no spacer divs.
- Semantic landmarks and heading hierarchy.
- Every link/button that should navigate uses a real react-router `Link`/
  `Button to=`, never `href="#"`. The catalog's course cards should link to
  `/cursos-diplomados/detalle`.
- Reuse `CourseCard` for the catalog grid. Reuse other existing components
  (`Button`, `FormField`, `SelectField`, `SectionHeading`, `Breadcrumb`,
  `FaqAccordion`) before inventing new ones.
- If the catalog needs filter/category data, or the course list itself,
  centralize it as `src/content/courses.ts` (typed), following the shape of
  `src/content/contact.ts`. This file is this task's alone — no other task
  touches it.
- `src/router.tsx` already has both routes wired — don't edit it unless
  adding a genuinely new sub-route.

## Verification

`bun run build`, `bun run lint`, `bun run format:check` all clean. Drive a
real dev server and check both pages at desktop and mobile widths with zero
console errors (Playwright is fine if there's no display). Compare against
`get_screenshot` for both frames.

## Deliverable

`src/pages/CursosDiplomados.tsx` and `src/pages/CursoDetalle.tsx` fully
converted, no longer using `PagePlaceholder`, verified live, navigable
catalog → detail. Leave changes uncommitted — Captain reviews and lands.
