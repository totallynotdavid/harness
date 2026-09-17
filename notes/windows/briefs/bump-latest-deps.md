Outcome: every dependency in `pyproject.toml` (main + dev groups) is at its latest
compatible release, not the version carried over as-is from the old `requirements.txt`
during the uv migration. `uv.lock` reflects the bump.

Constraints:

- This branches from `cap/uv-ruff-mise` (the uv/ruff/mise migration, already merged/
  open as PR #2) — you're extending that PR, not starting from scratch. Do not redo the
  tooling migration itself.
- Bump every package in `[project.dependencies]` and `[dependency-groups.dev]` to its
  latest release compatible with `requires-python = ">=3.12"` — `uv lock --upgrade`
  followed by `uv add <pkg>` for anything that needs its pin relaxed, or just edit
  `pyproject.toml` version specifiers directly and run `uv lock`. Prefer unpinned or
  `>=` specifiers over exact `==` pins where this repo's own convention allows it — check
  how the earlier task justified the current pins (platform markers for `pywin32`/
  `pygrabber`/`comtypes` must stay, those aren't about version pinning).
- `av`, `opencv-python-headless`, `zxing-cpp`, and `pywin32` are the packages most likely
  to have breaking changes between versions (video decode, barcode decode, Windows COM
  API) — after bumping, re-read their changelogs (WebSearch or the package's own GitHub
  releases) for anything that would change this app's behavior (`app/android_camera.py`,
  `app/decoder.py`, `app/scanner.py`, `app/excel_io.py` are the consumers), not just bump
  blindly and hope tests catch it.
- Do not touch anything unrelated to dependency versions — no code changes beyond what a
  version bump actually forces (an API that moved, a deprecated function).

Evidence:

- `uv sync` succeeds with the bumped lockfile.
- `uv run pytest -q` passes with the same pass/skip count as before the bump (or explain
  any change).
- `uv run ruff check .` stays clean.
- Report the before/after version table (every package, old pin -> new version) so the
  captain can see exactly what moved without re-diffing `uv.lock` by hand.
- If any package's latest version is a genuine downgrade risk (breaking change your
  research surfaced, or it fails at runtime in a way tests don't catch, e.g. camera/COM
  code untestable on Linux), say so plainly and pin it back with a one-line reason in a
  `pyproject.toml` comment, rather than silently bumping past a real risk.
