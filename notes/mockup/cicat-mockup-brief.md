# Turn the CICAT Salud Figma mock into a static HTML mockup, one page per frame

This is a brand-new, empty repo (`mockup`, at `/home/dubu/git/mockup`). It has
one seed commit with `assets/` (real image/icon assets already downloaded
from Figma for the Contacto page). There is no existing app to match
conventions against — you are establishing the conventions, and the
reference file below is the standard to follow for every other page.

## Source

Figma file "Mock" (David's Starter team), file key `wetbbJa7crTH0ZqbtVPpur`.
It is a full marketing site mockup for CICAT Salud, a Peruvian health-training
institution, laid out as three top-level Figma sections containing 20 frames
total (one frame = one screen).

You have the Figma MCP plugin available in this session
(`mcp__plugin_figma_figma__*` tools). Load the `figma-design-to-code` skill
(or read `skill://figma/figma-design-to-code/SKILL.md`) before calling
`get_design_context` — it is mandatory and explains the workflow, including
how to render every icon/image from its real exported asset rather than
hand-drawing one.

## Frames to produce (fileKey `wetbbJa7crTH0ZqbtVPpur`)

Desktop:
- `1:43` Home → `home.html` — **large**, will not fit one `get_design_context`
  call (confirmed: it returns a "too large, call get_design_context on
  sublayers" sparse response). Split into its major top-level sections (the
  metadata below lists ~90 direct children of this frame; group adjacent
  small decorative rectangles with the section they belong to) and stitch the
  converted sections into one `home.html`, in their original vertical order.
- `1:1028` Nosotros → `nosotros.html`
- `1:1490` Curso/diplomados → `cursos-diplomados.html`
- `1:2089` Verificación de certificado → `verificacion-certificado.html`
- `1:2305` Contacto → **already done**, see Reference below.
- `1:2633` Noticias → `noticias.html`
- `1:2914` Detalle de la noticia → `noticia-detalle.html`
- `1:3199` Detalle del curso → `curso-detalle.html`

Carrito de compras (desktop + mobile checkout flow):
- `1:3656` Completar tus datos - Desktop → `checkout-datos-desktop.html`
- `1:3961` Pago - Desktop → `checkout-pago-desktop.html`
- `1:4216` Completar tus datos - Mobile → `checkout-datos-mobile.html`
- `1:4510` Pago - Mobile → `checkout-pago-mobile.html`

Mobile home (note two frame pairs share a Figma layer name; use the node id
to tell them apart, and give them distinct file names as below):
- `1:4713` CURSOS / DIPLOMADOS → `mobile-cursos-diplomados.html`
- `1:5299` HOME → `mobile-home.html`
- `1:6110` NOSOTROS → `mobile-nosotros.html`
- `1:6578` CURSOS / DIPLOMADOS → `mobile-cursos-diplomados-2.html`
- `1:6967` NOTICIAS → `mobile-noticias.html`
- `1:7237` NOTICIAS DETALLE → `mobile-noticias-detalle.html`
- `1:7390` VERIFICACIÓN → `mobile-verificacion.html`
- `1:7600` NOTICIAS DETALLE → `mobile-noticias-detalle-2.html`

If any of these node ids come back not found, re-run `get_metadata` on the
file (no nodeId, to list top-level pages, then drill into `0:1`) to
reconfirm — the file may have changed since this brief was written.

## Reference: `contacto.html`

`/home/dubu/git/captain/notes/mockup/contacto-reference.html` is a finished,
verified conversion of the Contacto frame (`1:2305`). Copy it into the repo
as `contacto.html` unchanged, and use it as the pattern for every other page:

- Plain static HTML, no build step. Tailwind via the CDN script
  (`<script src="https://cdn.tailwindcss.com">`) with a small inline
  `tailwind.config` extending `theme.colors` with the CICAT design tokens
  (already in the reference file: `cicat-boton #facc15`, `cicat-azul-texto
  #122545`, `cicat-turquesa #0edad5`, `cicat-azul #2f4b74`, `cicat-azul-boton
  #dfe9f5`, `cicat-texto #565656`, `cicat-gris #d9d9d9`, `cicat-azul-footer
  #07142a` — reuse these tokens verbatim across every page instead of
  reinventing per-page color names).
- Google Fonts Inter, same `<link>` tags as the reference.
- The generated Tailwind/JSX code from `get_design_context` translates almost
  1:1: `className` → `class`, self-closing non-void tags (`<div ... />`)
  MUST become properly closed (`<div ...></div>`) — HTML does not treat a
  trailing `/>` on `div`/`span`/etc. as self-closing, so leaving it as-is
  breaks nesting. Strip `data-node-id`/`data-name` attributes. Resolve any
  parametrized sub-components (e.g. the reference's Figma-generated
  `TextHeader` component with ternary props) into their concrete rendered
  markup per usage — do not carry component/ternary logic into static HTML.
  Simplify `var(--color-/-x,DEFAULT)` wrapped values down to just `DEFAULT`.
- Real images/icons only, downloaded from the asset URLs `get_design_context`
  returns, saved under `assets/<figma-asset-uuid>.<ext>` (the UUID is the
  last path segment of the asset URL before the extension — use it verbatim
  as the filename so identical assets naturally dedupe across pages), and
  referenced by that local relative path. Never hand-draw an icon or leave a
  placeholder.
- Nav links between pages use the real file names above (see the reference's
  header nav `<a>` tags) so the mockup is click-through navigable, not just
  static images.
- Frames are fixed-width desktop (1440px) or mobile (whatever width Figma
  gives the mobile frames — check each frame's width in metadata and match
  it), laid out with `absolute` positioning matching the Figma frame
  coordinates exactly, same as the reference. Total page height should match
  the frame's Figma height (see the trailing spacer div in the reference).

## Verification

Open each generated HTML file directly in a browser (`file://` is fine, no
server needed) and confirm it visually matches the Figma screenshot for that
frame (`get_screenshot` gives you one) — same layout, same real copy, no
broken image icons, no leftover JSX/template syntax rendered as visible text.
Also grep the repo for `undefined`, `{isTexto`, `data-node-id`, and `/>`
directly followed by a non-void tag name pattern, as a mechanical check that
no JSX artifacts leaked through.

## Deliverable

All 20 `.html` files at the repo root, `assets/` holding every real
downloaded image/icon referenced by them, nothing left as a placeholder or
broken link.
