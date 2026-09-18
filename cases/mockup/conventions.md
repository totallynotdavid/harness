# mockup conventions

Initialized from: AGENTS.md

Project-specific rules for cap check and review.
Project instruction files remain authoritative.

## Surfaces

Files that should change together.

```surfaces
# changed-pattern -> required-pattern
# ^src/cli/ -> ^docs/
```

## House norms

Project-specific rules that change or extend the default checks.

## Subsystem invariants

System rules that cannot be detected from a diff alone.

## Gate-miss ledger

cap deliver writes an entry for every blocker or major finding raised after an
earlier gate round passed the same bytes. Add human-caught misses by hand.

- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/VerificacionCertificado.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/VerificacionCertificado.tsx:45` Verification only recognizes three hardcoded DNI fixtures; every other valid certificate holder is reported as not found because no backend lookup occurs. (finding c949e17d, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Privacidad.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Privacidad.tsx:20` The privacy route contains only a preparation placeholder, so users cannot review how CICAT Salud collects, uses, protects, or discloses personal data. (finding 5fc972a3, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Reclamaciones.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Reclamaciones.tsx:20` The complaints route contains only a preparation placeholder, so users have no complaint form or procedure for submitting a claim. (finding e0ebd2c2, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Reembolso.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Reembolso.tsx:20` The refund route contains only a preparation placeholder, so users cannot review refund eligibility or request instructions. (finding f48aaf66, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Terminos.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Terminos.tsx:20` The terms route contains only a preparation placeholder, so users cannot review the conditions governing the service. (finding 9c4ea7b5, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Privacidad.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Privacidad.tsx:20` The privacy-policy route renders only a placeholder, so users cannot review the data-use notice referenced by consent forms. (finding 6b5cc93d, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Terminos.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Terminos.tsx:20` The terms route contains no actual terms, leaving users without the conditions governing the service. (finding 7b6d8fc5, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Reclamaciones.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Reclamaciones.tsx:20` The complaints-book route provides no complaint form, instructions, or submission path. (finding 9aa792e4, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/pages/Reembolso.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/pages/Reembolso.tsx:20` The refund-policy route provides no refund conditions or request process. (finding 1143b22c, missed by gate A)
- 2026-09-18 ux-verificacion-legal: gate A (haiku) passed `src/router.tsx` at 8aed000; gate B (luna) then found, in the same bytes: [major] `src/router.tsx:32` The new legal routes are not reachable through the visible UI because footer legal labels and consent “Ver aquí” labels remain plain text rather than links. (finding 5485b5d5, missed by gate A)
