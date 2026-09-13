# Turn the CICAT Salud Figma port into a real, deployable site

`mockup` (`/home/dubu/git/mockup`) currently holds a straight port of a Figma mock:
24 React files (12 desktop/mobile page *pairs*), Tailwind loaded from the CDN
`<script>` tag, plain JS/JSX, absolute-pixel positioning copied straight from
Figma frame coordinates, and a mixed npm+bun setup. That version is landing to
`master` now as a checkpoint, purely so the work isn't lost. Your job is not to
patch it — it's to replace its structure with something a real team would ship,
using the same visual design and the same real Figma-exported assets it
already has.

This is the **foundation** task: tooling, information architecture, the shared
layout, and full conversion of two representative pages, done carefully and
verified in a live dev server. Do not try to convert all ten pages in one pass
if you're running low on steam — a solid foundation plus two fully-correct
reference pages beats ten shallow ones. Report back once the foundation and
the two reference pages are solid; the remaining pages get split out
separately once your pattern is proven (that's a deliberate sequencing
choice — foundation before parallel work, not a limitation of this task).

Load the `figma-design-to-code` skill and use `mcp__context7__*` (resolve
then query-docs) for anything you're not 100% certain about in oxfmt,
Tailwind v4, or react-router — don't guess at current APIs, they move fast.
Below is what was already confirmed via Context7 today (2026-09-11); treat it
as a starting point, not gospel — re-verify if something doesn't match.

## Decisions (stated so you can override them with evidence, not guess at them)

**Package manager: bun only.** Delete `package-lock.json`. Keep `bun.lock`.
Keep `mise.toml` pinning `bun = "latest"` (this project's own toolchain pin,
not a task-runner — `mise` only pins versions here, plain `bun run <script>`
stays the entry point, per this repo's own convention).

**Base tooling on `~/git/react-vite`** (a scaffold generated fresh via
`npm create vite@latest react-vite -- --template react-ts` — React 19, Vite 8,
TypeScript, oxlint already wired). Copy its `tsconfig*.json`, `.oxlintrc.json`,
and `vite.config.ts` shape into `mockup` rather than retrofitting the old
Vite 5 / React 18 / plain-JS setup. Its `.oxlintrc.json`:

    { "plugins": ["react", "typescript", "oxc"],
      "rules": { "react/rules-of-hooks": "error",
                 "react/only-export-components": ["warn", {"allowConstantExport": true}] } }

Its `tsconfig.app.json` is strict: `noUnusedLocals`, `noUnusedParameters`,
`erasableSyntaxOnly`, `jsx: react-jsx`, `moduleResolution: bundler`. Match it.

**Language: TypeScript.** Every component and page becomes `.tsx`; shared
data (nav links, footer columns, contact details) gets real types.

**Formatting: oxfmt.** Confirmed current and real (`bun add -D oxfmt`,
Prettier-compatible workflow, `oxfmt --init` for `.oxfmtrc.json`, `oxfmt --check`
to verify without writing). Add `format`/`format:check` scripts alongside the
existing `lint` script. Query Context7 (`/websites/oxc_rs_guide_usage`) if you
need config details beyond quickstart.

**Styling: Tailwind v4 via the official Vite plugin, not the CDN script, not a
JS config file.** CDN Tailwind is a prototyping tool, not something you ship.

    bun add tailwindcss @tailwindcss/vite
    // vite.config.ts
    import tailwindcss from '@tailwindcss/vite'
    export default defineConfig({ plugins: [react(), tailwindcss()] })
    /* src/index.css */
    @import "tailwindcss";
    @theme {
      --color-cicat-boton: #facc15;
      --color-cicat-azul-texto: #122545;
      --color-cicat-turquesa: #0edad5;
      --color-cicat-azul: #2f4b74;
      --color-cicat-azul-boton: #dfe9f5;
      --color-cicat-texto: #565656;
      --color-cicat-gris: #d9d9d9;
      --color-cicat-azul-footer: #07142a;
    }

Those are the exact tokens already used throughout the current port — keep
the same hex values, just move them from `tailwind.config` JS to CSS `@theme`
(Tailwind v4 is CSS-first config; verify current syntax via Context7,
`/tailwindlabs/tailwindcss.com`, if anything here looks off).

**Routing: the unified `react-router` package (v7), not `react-router-dom`.**
`createBrowserRouter` with one shared layout route:

    { element: <Layout />, children: [
      { index: true, element: <Home /> },
      { path: 'nosotros', element: <Nosotros /> },
      ... ,
    ]}

`Layout` renders `<Header/>`, `<Outlet/>`, `<Footer/>` once — pages stop
importing Header/Footer themselves. Verify current API shape via Context7
(`/websites/reactrouter`) since v6→v7 changed the package name.

## The real restructuring: collapse desktop/mobile pairs into responsive pages

This is the point of the task — not just a tooling swap. Every page currently
exists twice (a 1440px desktop version and a separate mobile version) with
duplicated content and duplicated absolute-pixel layout. Merge each pair into
**one** responsive component using Tailwind breakpoints. Old files → new page,
under `src/pages/`:

| Desktop file(s) | Mobile file(s) | New component | Route |
|---|---|---|---|
| `Home.jsx` | `HomeMobile.jsx` | `Home.tsx` | `/` (index) |
| `Nosotros.jsx` | `NosotrosMobile.jsx` | `Nosotros.tsx` | `/nosotros` |
| `CursosDiplomados.jsx` | `CursosDiplomadosMobile.jsx` (+ the 2nd mobile dup, same content) | `CursosDiplomados.tsx` | `/cursos-diplomados` |
| `VerificacionCertificado.jsx` | `VerificacionCertificadoMobile.jsx` | `VerificacionCertificado.tsx` | `/verificacion-certificado` |
| `Contacto.jsx` | `ContactoMobile.jsx` | `Contacto.tsx` | `/contacto` |
| `Noticias.jsx` | `NoticiasMobile.jsx` | `Noticias.tsx` | `/noticias` |
| `NoticiaDetalle.jsx` | `NoticiaDetalleMobile.jsx` (+ 2nd dup) | `NoticiaDetalle.tsx` | `/noticias/detalle` |
| `CursoDetalle.jsx` | `CursoDetalleMobile.jsx` | `CursoDetalle.tsx` | `/cursos-diplomados/detalle` |
| `CheckoutDatosDesktop.jsx` | `CheckoutDatosMobile.jsx` | `CarritoDatos.tsx` | `/carrito/datos` |
| `CheckoutPagoDesktop.jsx` | `CheckoutPagoMobile.jsx` | `CarritoPago.tsx` | `/carrito/pago` |

Ten pages, not twenty-four files. `/noticias/detalle` and
`/cursos-diplomados/detalle` are static stand-ins (there's no CMS/data layer
yet) — don't build dynamic `:slug` routing for content that doesn't exist;
say so plainly rather than half-building it.

To merge a pair: read both source files, treat the desktop version as the
`lg:`/`xl:` layout and the mobile version as the base (mobile-first) or
`max-*` layout — use your judgment on which reads cleaner, but the result
must be one component, one set of copy, real Tailwind responsive prefixes,
not two divs toggled by a media query hack.

## Replace the Figma-port layout technique with real document flow

The current pages are `absolute`-positioned boxes with literal Figma pixel
coordinates (`left-[calc(29.17%+51.5px)]`, `top-[188px]`), each page ending in
a trailing spacer div (`<div className="h-[2147px]" />`) just to force the
document to be tall enough. That's a screenshot pretending to be a webpage.
Replace it with normal flow: flexbox/grid, intrinsic sizing, no spacer divs,
no page-long absolute stacks. Keep the visual result faithful to the Figma
design — same spacing, same proportions — but let the browser size the page.

Use semantic landmarks: `<header>`, `<nav>`, `<main>`, `<section>`,
`<footer>`, and a real heading hierarchy (currently everything is `<p>`/`<div>`
soup with no `<h1>`/`<h2>`). Give every input a real associated label, real
`aria-label`s on icon-only controls (social icons, the cart icon), and replace
`alt=""` with real alt text where the image is meaningful (course photos,
the map) vs. decorative (background gradients, icon glyphs — `alt=""` is
correct there, don't blanket-fix it).

## Componentize repeated patterns

Pull these into `src/components/`: a `ContactInfoItem` (icon-in-circle +
label + value, repeated 5x on Contacto), `SocialLinks`, a `FormField` (label +
input, repeated across the contact and checkout forms), a `Button` (there are
at least 3 visually distinct button styles reused across pages), and a course
/ news card if the same card shape repeats across Home, Noticias, and
CursosDiplomados (check — it likely does). `Breadcrumb` already exists as a
component, keep it, just retype it.

Centralize content data under `src/content/`: nav links (already centralized
in `Header.jsx` as `NAV_LINKS` — good, extend the same pattern to footer link
columns, contact details, and social links, which are currently copy-pasted
per page).

## Assets

Keep everything under `public/assets/`, referenced by absolute path
(`/assets/<uuid>.<ext>`) — do not try to rename ~200 Figma-UUID-named files by
hand for this pass; that's a real cost for no functional gain, note it as an
accepted tradeoff rather than silently leaving it undone. Two exceptions to
fix: `public/assets/.png` and `public/assets/.svg` (literally no basename —
an extraction bug from the original conversion). Find what references them
(`grep -rn 'assets/\.' src/`) and either re-fetch the correct asset from Figma
via `get_design_context`/the asset URL, or remove the reference if it was
dead. Don't leave a broken image.

## Verification

- `bun install && bun run dev`, then click through every route in a real
  browser at both desktop and mobile widths (resize the window / device
  toolbar). Compare against `get_screenshot` for the two reference pages you
  fully convert.
- `bun run lint` (oxlint) and `oxfmt --check` both clean.
- `tsc -b` (or `bun run build`) clean — no TS errors.
- No console errors/warnings in the browser.
- No leftover absolute-pixel-Figma-frame layout in the two reference pages.

## Deliverable for this task

Tooling foundation in place (bun-only, TS, oxlint+oxfmt, Tailwind v4 via
Vite plugin, react-router v7 with a shared Layout route) across the whole
`src/`, **and** two pages — `Home` and `Contacto` — fully converted to the
responsive, semantic, componentized pattern described above, verified live.
The other eight pages can be stubs that at least route correctly (even a
"not yet migrated" placeholder is fine for them at this stage) — do not
half-convert them; either fully match the new pattern or leave them clearly
marked as pending.
