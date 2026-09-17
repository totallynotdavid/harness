Outcome: this repo's developer documentation is centralized and in English, structured
the way `dandavison/delta` structures its docs — the captain's named reference. The
current single 14KB Spanish `README.md` (mixing end-user portable-exe instructions, dev
source install, PyInstaller build/recompile internals, Personal-sheet usage, config
reference, and troubleshooting) gets split by audience, not just translated in place.

Read first: `dandavison/delta`'s actual doc layout (`README.md`, `CONTRIBUTING.md`,
`ARCHITECTURE.md`, `manual/`) — pull the real files via `gh`, don't work from memory of
what a "good README" looks like.

Decision made this session, stated so it can be corrected: this app's actual end users
are CICAT event staff running the portable `.exe` at a live event, who need
Spanish operating instructions — that's an operational necessity, not a documentation
style choice, and it's a different thing from the repository's developer docs. So:

- `README.md` (English): short pitch, what the app does, quick start for a developer
  cloning the repo (`mise install`, `uv sync`, `uv run pytest`), links out to
  `CONTRIBUTING.md` / `ARCHITECTURE.md` / the operator guide. Mirror delta's README
  tone and length — a pitch and a get-started, not the whole manual inlined.
- `CONTRIBUTING.md` (new, English): dev setup, codebase overview (what `app/*.py` each
  own, same shape as delta's "The codebase" section), useful commands (`uv run pytest`,
  `uv run ruff check`, `uv run ruff format`).
- `ARCHITECTURE.md` (new, English): the internals currently buried in README — camera
  backends (Android USB vs. Windows webcam), the Excel COM vs. openpyxl backend split,
  the PyInstaller portable-build optimizations, threading model (`ExcelWorker`,
  `PipelineWorker`, the Tk event loop). This is exactly what `rules/comments.md`'s "move
  the explanation to documentation" already argues for — check if any file-header
  docstrings in `app/*.py` are carrying subsystem-wide explanations that belong here
  instead, and move them, don't duplicate.
- A Spanish operator guide (new — name it clearly, e.g. `GUIA_OPERADOR.md`, not
  `README.md`, so it's obviously not the repo's front door): the actual portable-exe
  end-user instructions currently in README section 0 (install, "Personal" sheet setup,
  connecting the phone, running Autoprueba) — translated faithfully, not summarized, kept
  in Spanish because the people who read it at an event don't read English. Apply
  `AGENTS.md`'s "Write plainly" standard the same way the UI-copy task did.
- `THIRD_PARTY.md` stays as-is (already a standard attribution file, not part of this
  reorg) unless it references paths this task moves.

Small comment fix while you're in this repo (not part of the doc split, but same session
worth doing): `# ENTRADA | SALIDA | DUPLICADO` is duplicated verbatim in `attendance.py:13`
and `pipeline.py:20`. `models.py` already defines these constants — move the explanation
of what the three values mean onto the `models.py` definitions (or wherever they're
canonically defined) and drop the duplicate copies, so it's stated once. Skip this if it
turns out `models.py` doesn't actually own the definitions, and say why.

Constraints:

- Do not touch app behavior, tests, or the tooling from the `uv-ruff-mise`/
  `bump-latest-deps` work — this is a pure documentation reorg.
- No content loss: every real instruction in the current README must land somewhere
  (English dev docs or the Spanish operator guide) — this is a split, not a rewrite that
  drops detail. Read the whole current README before starting, and check off each
  section against where it landed.
- Cross-link the split files (README -> CONTRIBUTING/ARCHITECTURE/operator guide) so a
  reader starting at any one of them can find the others.

Evidence: a table in the final report mapping every current README section (by its
existing header) to where it ended up (which new file, or "removed because
[reason]") — a reviewer should be able to check the split is complete without re-reading
both versions end to end.
