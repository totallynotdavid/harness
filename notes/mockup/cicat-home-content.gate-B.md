No stale references, no test suite. The refactor is clean: TypeScript compiles, assets referenced by the shared `courses.ts`/`news.ts` all exist on disk, the badge filter preserves the original 6-course catalog order/content, and this correctly deduplicates data that was already duplicated across `CursosDiplomados.tsx`/`Noticias.tsx`.

One minor nit (not a defect): the `CATALOG_COURSES` comment at `src/pages/Home.tsx:74-75` packs two ideas into one sentence via a semicolon, which `rules/comments.md` guidance (rule 5) says to split — but it's accurate and non-obvious, so it's not a functional problem.

GATE: PASS
