## Review

Build (`bun run build` → `tsc -b && vite build`), `oxlint`, and `oxfmt --check` all pass clean, and all `/assets/*` paths referenced in `src/` resolve to real files. The defects below are behavioral/content regressions introduced by the JSX→TSX/responsive-merge migration, found by diffing every new page/component against the deleted desktop+mobile originals at f5c02c8.

**1. Dead CTAs where working navigation existed before, despite the target routes now existing**
`router.tsx` defines `/cursos-diplomados`, `/cursos-diplomados/detalle`, `/nosotros`, `/noticias/detalle` specifically so cards/buttons can "link somewhere real" (per the placeholder comments), but several call sites were never wired up:
- `src/components/CourseCard.tsx:76-87` — "Ver programa" is a hardcoded `<a href="#">`. The old mobile `DiplomadoCard` (`HomeMobile.jsx`, ~line 7829) used `<Link to="/curso-detalle-mobile">`.
- `src/components/NewsCard.tsx:25-36` — "Leer más" is `<a href="#">` on just the CTA text. Old mobile `NewsCard` (`HomeMobile.jsx`, ~line 7842) wrapped the **entire card** in `<Link to="/noticia-detalle-mobile">`.
- `src/pages/Home.tsx:317-320` — category tiles (Cursos/Diplomados/ECSI) are `<a href="#">`. Old mobile (`HomeMobile.jsx:128-131`) used `<Link to="/cursos-diplomados-mobile">`.
- `src/pages/Home.tsx:395-407` — "Ver todos los programa" is a `<Button variant="secondary">` with no `to` prop, so `Button.tsx` renders an inert `<button type="button">`. Old mobile (`HomeMobile.jsx:374-377`) used `<Link to="/cursos-diplomados-mobile">`.
- `src/pages/Home.tsx:480-492` — "Sobre nosotros" button, same pattern; old mobile (`HomeMobile.jsx:409-415`) used `<Link to="/nosotros-mobile">`.

Failure: clicking any of these on the "fully migrated" homepage does nothing, where the pre-migration mobile experience actually navigated.

**2. `required` prop on form fields is cosmetic only, not applied to the DOM element**
`src/components/FormField.tsx:9` and `:36` destructure `required` to decide whether to render a `*`, but never forward it into `...inputProps`/`...selectProps` before spreading onto the real `<input>`/`<select>`. Used with `required` at `src/pages/Home.tsx:632-650` and `src/pages/Contacto.tsx:58-75`. Failure: every "required" field shows an asterisk but has zero HTML5 validation — both forms submit fully empty.

**3. Mobile-only floating WhatsApp CTA dropped from `Contacto.tsx`**
`ContactoMobile.jsx` (~line 4889) rendered a fixed circular WhatsApp button (`bg-[#25d366]`, icon `64ac8779-...svg`) over the contact section. `src/pages/Contacto.tsx` has no equivalent (verified: no `WhatsApp`/`25d366` reference). Unlike the placeholder pages, `Contacto.tsx` is a fully-ported page, so this is silent, mobile-exclusive content loss rather than deferred scope.

**4. Mobile-only hero copy silently replaced by desktop copy**
`HomeMobile.jsx` (~line 7943) had its own hero: "Ventilación Mecánica en Cuidados Intensivos" / "Programa de alto nivel clínico con simulación avanzada..." on a different background image. The merged `src/pages/Home.tsx:265-274` shows only the desktop hero ("Urgencias y Emergencias Hospitalarias") at every breakpoint. This may be an intentional consolidation, but it silently drops a distinct marketing message that used to reach mobile visitors — worth confirming intent rather than assuming it.

**5. `tsconfig.app.json` / `tsconfig.node.json` don't enable `"strict"`**
Neither new tsconfig sets `strict: true` (the standard Vite react-ts template does). Without it, `noImplicitAny`/`strictNullChecks` etc. are off, so this TS migration gets far weaker compile-time guarantees than a typical strict TS setup while still compiling cleanly.

**Not defects, for context only:** `CursosDiplomados`, `Nosotros`, `Noticias`, `NoticiaDetalle`, `CursoDetalle`, `VerificacionCertificado`, `CarritoDatos`, `CarritoPago` are all reduced to self-documented `PagePlaceholder` stubs ("no fue migrada al nuevo patrón... se incorporará en una siguiente iteración"), and the four Checkout Desktop/Mobile pages (real forms, ~600 lines) have no replacement beyond two placeholder stubs. This is declared intentional in-code, not a silent break, but it's a large scope reduction worth the user's explicit sign-off if not already agreed.

GATE: FAIL
