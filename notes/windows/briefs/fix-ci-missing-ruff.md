Outcome: `.github/workflows/ci.yml` and `.github/workflows/release.yml` actually pass on
GitHub's hosted runners. They currently fail immediately: `uv run ruff check .` errors
with `Failed to spawn: ruff / No such file or directory` (see run
https://github.com/cicatnet/windows/actions/runs/35092138520 — the CI run on push to
`main` after PR #4 merged, and the `v1.2.0` release run,
https://github.com/cicatnet/windows/actions/runs/35092198109, both fail the same way).

Root cause: `ruff` is pinned only in `mise.toml`, never declared as a `uv`
dependency. Locally, every verification so far ran through `mise exec -- uv run ...`,
which put `ruff` on `PATH` from mise's own install — that's why it worked in every local
check and was never caught before landing. The CI workflows use `actions/setup-python` +
`astral-sh/setup-uv` directly, with no mise involved at all, so `ruff` is simply absent.

Fix: make CI use `mise` too, via the official `jdx/mise-action`
(https://github.com/jdx/mise-action — SHA-pin it the same way every other action in
these workflows is pinned, full 40-char commit SHA with a trailing `# vX.Y.Z` comment,
verified real via `gh api repos/jdx/mise-action/commits/<sha>`). This keeps `mise.toml`
as the single source of truth for `python`/`uv`/`ruff` versions — do not instead add
`ruff` as a second, independently-versioned entry in `pyproject.toml`'s dev dependencies,
that would create two places pinning the same tool and let them drift.

Steps:

- In both workflow files, replace the `actions/setup-python` + `astral-sh/setup-uv` pair
  with `jdx/mise-action` (pinned), followed by `mise install` (or let the action run it),
  so `python`, `uv`, and `ruff` all come from what `mise.toml` declares. Confirm the
  action's actual input/output contract from its README before wiring it up — don't
  guess at option names.
- Every subsequent step that currently runs `uv run ...` should now run through mise so
  `ruff`/`uv` resolve (`mise exec -- uv run ...`, matching exactly how this repo's own
  local verification already works — check `README.md`/`CONTRIBUTING.md` if either
  documents the expected local command shape by this point, and keep CI consistent with
  it).
- Do not change what each step actually does (lint, test, build, package, publish) —
  only how the `python`/`uv`/`ruff` toolchain is provisioned.
- After the fix, this must be proven on GitHub, not just locally: push to a scratch
  branch (or use `gh workflow run` / open a throwaway PR against a disposable branch,
  your choice) and confirm the CI workflow actually goes green in a real Actions run —
  paste the run URL and its conclusion in your report. Local `mise exec -- uv run
  pytest`/`ruff check` passing is necessary but was already proven and is not sufficient
  evidence here, since that's exactly what didn't catch this bug.
- The `v1.2.0` tag already exists and its release run already failed
  (35092198109) — after this fix merges to `main`, delete the failed run's tag both
  locally and on the remote (`git push origin :refs/tags/v1.2.0`) so a fixed re-tag can
  reuse `v1.2.0` cleanly; do not leave a failed `v1.2.0` release artifact/tag around
  pointing at broken CI. Report this step explicitly rather than silently deleting a tag
  — it's a real action on the release history.

Evidence:

- A real GitHub Actions run of the CI workflow (link + conclusion) is green.
- A real GitHub Actions run of the release workflow, triggered by re-pushing `v1.2.0`
  once this fix is on `main` (or a test tag if you want to prove it before touching
  `v1.2.0` specifically — your call, but the final state must be a green `v1.2.0`
  release with a published GitHub Release and attached ZIP), is green end to end,
  including the actual publish step.
