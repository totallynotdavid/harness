# Gate A: ux-design-system

haiku reviewed the changes since 6d2e4555a393, with HEAD at 6d2e4555a393 (fingerprint 584abff2cdbd). Verdict: PASS.

## Findings

None.

## Checked

- `src/components/NavAffordance.tsx`: New component: small, focused, proper aria-disabled for keyboard accessibility, no issues
- `src/components/StatusMessage.tsx`: New component: role mapping correct (alert for errors, status for success/info), variant-driven styling via VARIANT_CLASSES map
- `src/hooks/useFormSubmission.ts`: New hook: proper useCallback memoization, dependency arrays correct, async handleSubmit with sync side effects works correctly with void operator in CarritoDatos
- `src/index.css`: New design tokens and utilities added: 12 color variables, shadow elevation system, z-index stacking order, .content-grid-sidebar layout class all properly defined
- `src/components/FormField.tsx`: Refactored to use StatusMessage component; placeholder color hardcoded value replaced with cicat-placeholder token; error role maintained
- `src/components/Header.tsx`: NavAffordance component replaces hardcoded span; z-index changed from hardcoded 50 to z-[var(--z-header)]; header colors to semantic tokens
- `src/components/CourseCard.tsx`: Colors replaced with tokens; shadow-lg → shadow-elevation-medium (Tailwind → custom variable)
- `src/components/TestimonialCard.tsx`: #fafafa → cicat-fondo-suave token
- `src/pages/CarritoDatos.tsx`: Grid layout changed from hardcoded 1fr_387px to .content-grid-sidebar class (1fr_25rem = 1fr_400px); form hook integrated; StatusMessage for errors; error color text-red-700 consistent
- `src/pages/CarritoPago.tsx`: StatusMessage component used for file upload errors and success messages; variant='success' maps to text-cicat-azul matching original
- `src/pages/CursoDetalle.tsx`: Grid from 1fr_420px to .content-grid-sidebar (1fr_400px, -20px sidebar); all color tokens replaced; objective/module headings use cicat-azul-oscuro token
- `src/pages/Contacto.tsx`: Grid from 387px_1fr to .content-grid-sidebar--reverse (25rem_1fr = 400px_1fr, +13px sidebar); FAB button z-index from 40 to z-[var(--z-fab)]
- `src/pages/Home.tsx`: Gradient overlay from hardcoded rgba to cicat-turquesa/80 token; shadow-lg → shadow-elevation-medium; all colors to tokens
- `src/pages/Nosotros.tsx`: Grid from 405px_1fr to .content-grid-sidebar--reverse (400px_1fr, -5px sidebar); gradient from hardcoded #143769 to cicat-azul-oscuro token; all color replacements correct
- `src/pages/VerificacionCertificado.tsx`: Button bg from #143769 to cicat-azul-oscuro; text colors to tokens
- `src/pages/NoticiaDetalle.tsx`: #fffbeb → cicat-alerta-fondo token for alert background
- `src/pages/Noticias.tsx`: shadow-lg → shadow-elevation-medium for featured card hover state
- `src/components/CarritoHero.tsx`: Gradient overlay from hardcoded rgba(14,218,213,0.8) and rgba(20,55,105,0.8) to cicat-turquesa/80 and cicat-azul-oscuro/80 tokens
- `src/components/CourseNotFoundBanner.tsx`: Alert background from #fffbeb to cicat-alerta-fondo token; trailing whitespace removed
- `src/components/InscripcionStepper.tsx`: Multiple color replacements: #143769 → cicat-azul-oscuro (4 instances), #516279 → cicat-gris-azul; consistency maintained across step indicators
- `src/components/NewsCard.tsx`: Hover shadow from shadow-lg to shadow-elevation-medium (Tailwind class to custom variable)
- `src/components/PageHero.tsx`: Default overlay gradient from hardcoded rgba to cicat-turquesa/80 and cicat-azul-oscuro/80 tokens; applies to multiple hero sections
- `src/components/SectionHeading.tsx`: Eyebrow text color from #516279 to cicat-gris-azul token
- `src/pages/CursosDiplomados.tsx`: Search and filter inputs: border and text colors from #516279 to cicat-gris-azul; placeholder colors to token; trailing whitespace removed
