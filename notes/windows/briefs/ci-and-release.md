Outcome: `cicatnet/windows` gets CI (fast checks on every PR and push to `main`) and a
release workflow that builds and publishes the portable Windows ZIP when a maintainer
pushes a `vMAJOR.MINOR.PATCH` tag.

Read `/home/dubu/git/captain/notes/windows/ci-release-scout.md` first (in the captain
repo, one level above this worktree's origin) — a scout already read this repo's real
build script, cited five mature repos' actual release workflows (yt-dlp, hydrus,
anylabeling, angr-management, Dioptas) with links, and reached a specific
recommendation. Implement that recommendation; do not re-research it from scratch. The
sections below restate its decisions as constraints.

Constraints:

- Two workflow files: a fast one (`uv run ruff check .` + `uv run pytest` on
  `ubuntu-latest`, triggered on every pull request and on push to `main`, no Windows
  build) and a release one (triggered only on push of a `v*.*.*` tag: runs the same fast
  checks first, then builds on `windows-latest` with `uv sync` against the locked
  `uv.lock`, runs the existing `uv run tools/build_portable.py` unchanged, then a small
  Ubuntu job publishes the resulting ZIP to a GitHub Release via `gh release create`).
- Every `uses:` entry in both workflows is pinned to a full 40-character commit SHA,
  never a tag (`@v4`, `@v1`, `@main` are all refused) — with a trailing `# vX.Y.Z`
  comment naming the version that SHA corresponds to, for readability and future
  Dependabot updates. This is non-negotiable; the scout report names which of the five
  researched repos actually do this (hydrus, and yt-dlp's `build.yml`/`release.yml`) as
  the pinning precedent to follow — look at their actual pinned lines, don't invent a
  format.
- Use `astral-sh/setup-uv` (SHA-pinned) rather than a manual `pip install uv` step — the
  scout compared both and the official action is the better fit given this repo already
  pins `uv` via `mise.toml`. Pin the same `uv` version `mise.toml` declares. Cache keyed
  from `uv.lock` (fallback `pyproject.toml`).
- The release job stages `../AsistenciaDNI_Portable.zip` (the build script writes it one
  directory above the repo root — read `tools/build_portable.py` yourself to confirm the
  exact path before writing the upload step) and renames the uploaded asset to
  `AsistenciaDNI_Portable-vX.Y.Z.zip`. Do not replace or reimplement the packaging logic
  in `tools/build_portable.py`/`AsistenciaDNI.spec` — the workflow only invokes it.
- Before wiring up tag-triggered releases, resolve the version conflict the scout found:
  `pyproject.toml` says `version = "0.1.0"`, but `tools/version_info.txt` already embeds
  `1.2.0` in the built executable. Make `pyproject.toml`'s `version` the canonical source
  (seed it to `1.2.0` to match what's already shipped), and make the release workflow
  generate or validate `tools/version_info.txt` from that value rather than trusting two
  independent numbers to stay in sync.
- `GITHUB_TOKEN` only, scoped to `contents: write` on the publishing job alone (not
  workflow-wide). No signing secret, no PAT — signing stays out of scope, the app is
  unsigned today.
- Do not attempt to run the GUI, a physical USB camera/ADB device, or Microsoft Excel COM
  automation in CI — none of that is reliable on a hosted runner. The release job's own
  verification is limited to: the build produced the expected `.exe`, the ZIP exists, and
  the ZIP contains the portable executable (existence/size checks, not a functional
  test).
- This branches from `cap/bump-latest-deps` (PR #3, stacked on PR #2's
  `cap/uv-ruff-mise`) — confirm that branch exists and build on its tip, not on `main`,
  since `main` doesn't have `pyproject.toml`/`uv.lock`/`mise.toml` yet. Neither PR #2 nor
  PR #3 is merged yet; this task stacks on top of both the same way #3 stacks on #2.

Evidence:

- Both workflow files pass `actionlint` (or equivalent YAML/schema validation available
  in this environment) if such a tool exists; if not, at minimum confirm valid YAML and
  that every `uses:` line matches `owner/repo@<40-hex-char-sha> # vX.Y.Z` — grep for any
  `uses:` line that doesn't match that shape and treat one as a failure.
  a lightweight `git tag v0.0.0-test && git push` from a disposable
  fork/branch is not expected — describe in your report exactly what you did verify
  (workflow syntax, the SHA pins resolve to real commits on the named repos via `gh api`)
  versus what only a real GitHub Actions run would prove.
- Confirm via `gh api repos/<owner>/<action-repo>/commits/<sha>` (or `gh api
  repos/.../git/commits/<sha>`) that every pinned SHA actually exists and corresponds to
  the version named in its trailing comment — a wrong or stale SHA pin is worse than a
  tag, since it's silently unreviewable.
- `pyproject.toml`'s version and `tools/version_info.txt` agree, and the release workflow
  step that keeps them in sync is demonstrated (a dry run of whatever mechanism you add,
  not just described).
