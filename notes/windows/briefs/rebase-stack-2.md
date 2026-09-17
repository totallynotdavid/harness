Outcome: `cap/bump-latest-deps` (PR #3) and `cap/ci-and-release` (PR #4) rebase cleanly
onto the current `origin/main` and become mergeable again.

Context: PR #2 (`cap/uv-ruff-mise`) was just merged into `main` via GitHub's rebase-merge
strategy, which rewrites commit SHAs even though content is identical. PR #3 was
retargeted from `cap/uv-ruff-mise` to `main` and now shows CONFLICTING for that reason —
not a real content conflict, a SHA-identity mismatch from the rebase-merge.

Constraints:

- `git fetch origin main`, then `git rebase --onto origin/main <old-cap/uv-ruff-mise-tip>
  cap/bump-latest-deps` (or simply rebase onto `origin/main` directly — since the
  content is identical to what's now on `main`, this should be a clean, conflict-free
  rebase; if it isn't, stop and report the actual conflict rather than forcing past it).
- Then rebase `cap/ci-and-release` onto the new `cap/bump-latest-deps` tip the same way.
- Force-push both branches (same names) so PRs #3 and #4 update in place.
- Confirm `uv sync`, `uv run pytest`, `uv run ruff check .` still pass on both tips after
  the rebase.

Evidence: `gh pr view 3 --repo cicatnet/windows --json mergeable` and `gh pr view 4
--repo cicatnet/windows --json mergeable` both report `MERGEABLE` after the push.
