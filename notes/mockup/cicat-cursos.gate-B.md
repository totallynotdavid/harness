Consistent with existing repo convention (mockup, no backend actions wired) — not a new defect.

Everything checks out: TypeScript build and lint are clean, every referenced asset in `public/assets/cursos/` exists and is used, route wiring and `getCourseById` id-matching logic is correct (including the not-found fallback), the uncontrolled `SelectField` usage is intentional and documented, and the category/modality filter logic in `CursosDiplomados.tsx` correctly covers all course levels present in the data. No dead code, no debug artifacts, and comments are limited to non-obvious rationale per the repo's comment rules.

GATE: PASS
