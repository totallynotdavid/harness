Outcome: `cap/uv-ruff-mise` (PR #2) rebases cleanly onto current `main` and becomes
mergeable. `main` already has PR #1 merged (SUNAT + name-search), which independently
added its own `.gitignore` — that's the one real conflict: `cap/uv-ruff-mise` also added
a `.gitignore`, with different (also correct) content.

Constraints:

- `git fetch origin main`, then rebase `cap/uv-ruff-mise` onto `origin/main`.
- The `.gitignore` conflict resolves as a union of both versions' patterns, deduplicated,
  not a pick-one — both files are correct for what they cover (PR #1's covers
  `.venv/build/dist/vendor/testdata/config.json/__pycache__/.pytest_cache` plus the
  `data/logs/*.xlsx/*.csv` DNI-data exclusions; PR #2's covers `__pycache__/*.pyc` plus
  `build/dist/vendor/data/logs/config.json`). Keep every pattern from both, remove exact
  duplicates, keep it organized (group by "generated tooling output" vs. "never commit —
  contains real DNI data" the way PR #1's file already comments it).
- After resolving, confirm nothing else conflicts (the two PRs shouldn't have touched
  overlapping app code — PR #1 touched `app/pipeline.py`/`app/roster.py`/`app/ui.py`/
  `app/main.py`; PR #2 is a tooling migration that touched the same files only for
  import-formatting via `ruff format`, so check those specifically).
- Force-push the rebased branch (same branch name, `cap/uv-ruff-mise`) so PR #2 updates
  in place rather than opening a new PR. `cap/bump-latest-deps` and `cap/ci-and-release`
  are stacked on top of this branch (PRs #3 and #4) — after this rebase, check whether
  they need a rebase too (their own diffs shouldn't conflict with anything from PR #1,
  but verify rather than assume).

Evidence:

- `uv sync`, `uv run pytest`, `uv run ruff check .` all still pass after the rebase.
- `gh pr view 2 --repo cicatnet/windows --json mergeable` reports `MERGEABLE` after the
  push.
- Report whether PRs #3 and #4 needed their own rebase, and if so that they're clean too.
