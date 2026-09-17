Outcome: a report (not code) proposing how this repo should get CI and publish Windows
releases of the portable `.exe`, backed by real examples from mature repos, ready for
the captain to turn into an implementation brief.

Context: `/home/dubu/git/windows` (a.k.a. "Asistencia DNI") is a Python 3.12 desktop app
(tkinter UI, PyInstaller-built single-file `.exe` for Windows) that just migrated to
`uv` + `ruff`, pinned via `mise.toml` (see `mise.toml`, `pyproject.toml` at repo root).
It has no CI at all today (confirmed: no `.github/workflows`, no other CI config) and no
GitHub Releases. The README's `tools/build_portable.py` (invoked as
`.venv\Scripts\python tools\build_portable.py` today, `uv run tools\build_portable.py`
after the tooling migration) already does the actual PyInstaller build locally on
Windows — read it, and `AsistenciaDNI.spec`, before proposing a workflow, so what you
design drives the same build the maintainer runs by hand, not a reinvention of it. This
repo can only be built and run on Windows (uses `pywin32`, ADB/USB camera access,
WebView-style Excel COM integration) — any CI must run on a `windows-latest` (or
equivalent) runner; there is no way to build or test the real thing on Linux, which is
why this needs a scout, not an implementation, first.

Research:

- Use `gh` to look at real, mature open-source repos that build and release a Windows
  PyInstaller `.exe` via GitHub Actions — not a toy example. Pull actual workflow YAML
  from repos with real release history (`gh api`, `gh repo view`, cloning/reading
  `.github/workflows/*.yml` from a few candidates) rather than inventing one from
  memory. Look for: how they cache `uv`/pip, how they run PyInstaller on
  `windows-latest`, how they attach the built `.exe` to a GitHub Release (`gh release
  create`/`softprops/action-gh-release` or similar), and whether they run `pytest`/
  `ruff check` as a separate, faster job before the (slow) Windows build.
- Use context7 or WebSearch if you need current GitHub Actions syntax (`actions/
  setup-python`, `astral-sh/setup-uv`, `windows-latest` runner specifics, release-action
  options) rather than guessing at API shapes that may have changed.
- Check whether `astral-sh/setup-uv` (the official `uv` GitHub Action) is the right fit
  given this repo now uses `uv` — compare it against a manual `pip install uv` step in
  at least one real workflow you find.

Requirements the report must settle (state known vs. genuinely open for each):

- What triggers CI (push/PR on all branches? just `main`/`master`? — check what this
  repo's default branch is actually called) and what triggers a release build
  (a git tag? a GitHub Release draft? manual `workflow_dispatch`?).
- Whether "fast" checks (ruff, pytest — these can run on Linux, they're the same suite
  `uv run pytest`/`uv run ruff check` already pass on) should be a separate, cheaper job
  from the "slow" Windows PyInstaller build, so a PR gets fast feedback without waiting
  20+ minutes for a full exe build every time.
- How the built `.exe` reaches a GitHub Release: attached as a release asset on tag push,
  or only on manual dispatch — and whether the existing `AsistenciaDNI_Portable.zip`
  packaging (see README section 0) is what should actually be attached, not just the raw
  `.exe`.
- Versioning: is there any existing version scheme in this repo (check `wails.json`-
  equivalent, `pyproject.toml`'s `version`, any git tags) to build a release-naming
  convention on, or does one need to be introduced.
- Whether this needs secrets (a GitHub token beyond the default `GITHUB_TOKEN` — code
  signing is explicitly out of scope, this app is unsigned today per the README, don't
  introduce a signing requirement that doesn't already exist).

Evidence: your report cites the specific mature repos and workflow files you read (repo
name + path, not a paraphrase), states a clear recommendation (not a menu of options with
no pick — this scout should decide and say why, the same way a shaping note does), and
ends with what an implementation brief for this would need to specify. Do not write or
propose actual workflow YAML as final — a sketch to support the recommendation is fine,
but the real file is a follow-up implementation task's job once the captain reviews this.
