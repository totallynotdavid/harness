Outcome: this repo's Python tooling runs on `uv` (dependency management) and `ruff`
(lint + format), both version-pinned via `mise.toml`, replacing today's manual
`.venv` + `pip install -r requirements.txt` flow. Every documented install/build path
(README, `instalar.bat`, `tools/build_portable.py`) uses the new flow — nothing is left
half-migrated with two competing ways to install dependencies.

Constraints:

- `mise.toml` (new, repo root) pins `python`, `uv`, and `ruff` tool versions (see mise's
  own Python cookbook doc for the shape: `[tools]` with `python`, `uv = "latest"`,
  `ruff = "latest"`, pin exact resolved versions rather than leaving "latest" once you've
  picked one). Do not add a `[tasks]` section — this project's own README stays the one
  place that documents how to install, run, lint, and test; mise only pins the toolchain,
  it does not become a task-runner layer in front of `uv`/`ruff`/`pytest`.
- Replace `requirements.txt` and `requirements-dev.txt` with `pyproject.toml` +
  `uv.lock` as the single source of dependency truth — `uv add <pkg>==<pinned-version>`
  (and `uv add --dev` for the dev-only ones) for every entry currently in both files, so
  the exact pinned versions carry over unchanged. Delete both `.txt` files once
  `pyproject.toml`/`uv.lock` fully replace them — this is a clean break, not a
  transition period where both exist.
- Add a `[tool.ruff]` section to `pyproject.toml`. Match this repo's actual code: it's
  Python 3.12, uses `from __future__ import annotations` everywhere, and its own style
  is already fairly disciplined (see `app/roster.py`, `app/pipeline.py` for the bar) —
  don't invent a strict ruleset from scratch; a reasonable default rule set
  (`E`, `F`, `I`, `UP`, `B`) plus whatever the codebase's real patterns need excluded is
  enough. State in your report which rules you picked and why.
- Run `ruff format .` and `ruff check --fix .` once across the whole repository to
  establish a clean baseline, and commit that as its own change, separate from the
  tooling-config commit. This must land before any later task does manual comment
  cleanup — a second task is queued to clean up comments/docs style, and it needs to
  start from ruff's formatting already settled, not fight a reformat happening under it.
  Read the diff `ruff format` produces before committing it: if it reflows something in
  a way that damages readability (long dict/list literals, the `Registro`/`Config`
  dataclasses, etc.), that's worth flagging in your report, but don't hand-tune around
  ruff's formatting choices — accept them as the new baseline.
- Update `README.md` section 1 (source install), `instalar.bat`, and
  `tools/build_portable.py` to use `uv sync` (and `uv run` where a script currently does
  `.venv\Scripts\python ...`) instead of the current pip/venv flow. You cannot run these
  `.bat` files or verify a real Windows build from this Linux environment — same
  constraint the earlier `checkin` task on the old Wails project documented. Edit them
  correctly based on `uv`'s documented Windows CLI behavior, say plainly in your report
  that they're edited-but-unverified-on-Windows, and do not claim you ran them.
- Do not touch `AsistenciaDNI.spec` or PyInstaller packaging logic itself — this task is
  about how dependencies are installed and code is linted/formatted, not the build
  pipeline's packaging step.
- No behavior change to `app/`'s actual runtime code beyond what `ruff format`/
  `ruff check --fix` produces automatically. This is a tooling task, not a feature or
  cleanup task — do not manually rewrite comments or restructure functions here; that's
  explicitly a separate, later task's job.

Evidence:

- `uv sync` (in this Linux worktree) installs a working environment and
  `uv run pytest -q` passes the full existing suite (same pass count as before this
  task, since no runtime code should have changed beyond ruff's formatting).
- `uv run ruff check .` passes clean (zero violations) after the fix pass.
- `git diff --stat` for the ruff-format commit, reviewed by you before committing, with
  any concerning reflow called out by file/line in your report rather than silently
  accepted.
- Confirm in your report that `requirements.txt` and `requirements-dev.txt` no longer
  exist and nothing in the repo (scripts, README, CI config if any) still references
  them.
