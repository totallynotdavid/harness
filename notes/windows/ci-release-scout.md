# CI and Windows release scout

Date: 2026-09-16

## Recommendation

Add two workflows, with a deliberately cheap path for normal development and a Windows-only path for distributable releases:

- A fast CI workflow runs `uv run ruff check .` and `uv run pytest` on `ubuntu-latest` for every pull request, and on pushes to `main`. It does not build the executable.
- A release workflow runs only when a maintainer pushes a semver tag of the form `vMAJOR.MINOR.PATCH`. It first runs the same fast checks, then builds on `windows-latest` with the repository's locked `uv` environment and runs the existing `uv run tools/build_portable.py`. A final small Ubuntu job publishes the resulting ZIP to the GitHub Release.

The release asset should be the clean `AsistenciaDNI_Portable.zip`, not a bare `AsistenciaDNI.exe`. The existing build script already creates the ZIP with the executable, guide, batch utilities, and a fresh `config.json`, while deliberately excluding user data. The workflow may rename the uploaded asset to `AsistenciaDNI_Portable-vX.Y.Z.zip` for discoverability, but should not replace the packaging implementation.

Use the default `GITHUB_TOKEN` with job-level `contents: write` only in the publishing job. No personal access token, signing secret, or code-signing setup is needed. Signing remains out of scope because the application is currently unsigned.

Supply-chain requirement: every `uses:` entry in the proposed workflows must be pinned to a full 40-character commit SHA. This applies to first-party actions such as `actions/checkout`, `actions/setup-python`, `actions/upload-artifact`, and `actions/download-artifact`, as well as `astral-sh/setup-uv` or any release action. A trailing comment such as `# vX.Y.Z` is recommended for readability and Dependabot maintenance, but `@vX`, `@vX.Y`, and `@main` are not acceptable pins. The publication design should use the preinstalled `gh release create` CLI, avoiding a release-action dependency altogether; any action that remains must still be SHA-pinned.

## State of this repository

The checked-out `/home/dubu/git/windows` and this task worktree are at `main`/`fe77d39` (`Subida archivos base`). The default branch is confirmed as `main` (`origin/HEAD -> origin/main`). GitHub currently reports zero releases and no `.github/workflows` directory for `cicatnet/windows`.

The contract describes the later `uv` migration, and that migration exists locally on `cap/uv-ruff-mise` (`fe47c47`), but it has not been merged into `main`. That ref adds `pyproject.toml`, `uv.lock`, `mise.toml`, and removes the requirements files. The recommendation below assumes that ref (or its equivalent) is the intended implementation base; the workflow should not be added to the older `main` snapshot before the migration is available.

The migration ref declares:

- Python `>=3.12` in `pyproject.toml`;
- development dependencies including PyInstaller and pytest;
- `uv` `0.12.13`, Python `3.12.14`, and Ruff `0.16.7` in `mise.toml`;
- a locked dependency graph in `uv.lock`.

There is an existing version conflict that must be resolved before the first release tag: the migration's `pyproject.toml` says `version = "0.1.0"`, while `tools/version_info.txt` embeds `1.2.0` in the executable. There are no Git tags and no other project version source. I recommend adopting semver tags and making `pyproject.toml` the canonical version, seeded at `1.2.0` to match the already embedded application metadata; the build should generate or validate `tools/version_info.txt` from that value before a tag is published.

## What the current build actually does

I read the migration ref's `tools/build_portable.py` and `AsistenciaDNI.spec`.

`tools/build_portable.py`:

1. Runs `tools/descargar_scrcpy.py`, which downloads the official scrcpy 4.1 Windows ZIP and verifies SHA-256 hashes for every extracted file.
2. Runs `tools/crear_icono.py`.
3. Invokes PyInstaller with `AsistenciaDNI.spec`, `--clean`, and the existing `dist`/`build` paths.
4. Produces `dist/AsistenciaDNI.exe`.
5. Copies that executable plus `tools/portable/*` into `../AsistenciaDNI_Portable`.
6. Creates `../AsistenciaDNI_Portable.zip`, containing `AsistenciaDNI_Portable/AsistenciaDNI.exe`, the utilities, and a clean config.

The spec is a one-file, GUI-less build from `lanzador.pyw`; it collects `zxingcpp` and `av`, explicitly includes the COM/DirectShow imports and scrcpy files, embeds the Visual C++ runtime DLLs found on Windows, and excludes development modules. The workflow must therefore run the script itself on Windows. It must not replace the build with a Linux PyInstaller invocation or a second hand-written packaging path.

The README says this ZIP is the recommended portable distribution and documents the same build command. The parent-directory output is important: after the build, the workflow must stage `../AsistenciaDNI_Portable.zip` for artifact upload rather than assuming the ZIP is under the repository root.

## CI and release trigger decisions

| Concern | Decision | Status |
| --- | --- | --- |
| Default branch | `main` | Known from `origin/HEAD` and GitHub metadata |
| Normal CI | Pull requests with no branch restriction; pushes to `main` | Recommendation |
| Windows executable on PRs | No; do not spend 20+ minutes building an artifact for every PR | Recommendation |
| Release build | Push of `vMAJOR.MINOR.PATCH` | Recommendation |
| Draft-release trigger | No | Recommendation; tags are the source of release version truth |
| Manual release dispatch | No in the first implementation | Recommendation; add a separate recovery mechanism only if operations later require it |
| Release asset | Clean `AsistenciaDNI_Portable-vX.Y.Z.zip` | Recommendation based on existing packaging |
| Extra secret | None | Known, assuming repository Actions settings permit `contents: write` |

The release workflow should make the Ubuntu checks a prerequisite of the Windows build. The Windows job should then check that the expected executable and ZIP exist and that the ZIP contains the portable executable. A GUI launch, physical USB camera, ADB device, and Microsoft Excel COM test cannot be made reliable on a hosted runner; those remain manual/acceptance checks. The normal pytest configuration already excludes the Excel-marked tests by default.

## Evidence from mature repositories

These are real repositories with current release history and Windows executable assets, not illustrative snippets.

### yt-dlp/yt-dlp

The latest observed release was `2026.08.19`, with `yt-dlp.exe`, `yt-dlp_win.zip`, x86/x64/ARM64 Windows assets, and checksum files: [release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19).

Specific workflow evidence:

- [`.github/workflows/quick-test.yml`](https://github.com/yt-dlp/yt-dlp/blob/master/.github/workflows/quick-test.yml) runs core tests and code checks as separate Ubuntu jobs. It runs on pushes to `master` and every pull request, with Ruff in the code-check job; the expensive executable build is absent from this fast path.
- [`.github/workflows/build.yml`](https://github.com/yt-dlp/yt-dlp/blob/master/.github/workflows/build.yml) has a Windows matrix, installs pinned requirements with hashes, invokes its PyInstaller module, builds one-file and onedir variants, compresses the onedir build, and uploads artifacts. Its maintained workflow uses full SHA pins with trailing version comments, for example `actions/checkout@<sha> # v7.0.1` and `actions/upload-artifact@<sha> # v7.0.1`.
- [`.github/workflows/release.yml`](https://github.com/yt-dlp/yt-dlp/blob/master/.github/workflows/release.yml) downloads the build artifacts and uses `gh release create ... artifact/*` with `contents: write`. This is a useful model for separating build from publication and for publishing multiple prepared assets. Its action references are SHA-pinned with version comments.

yt-dlp is the strongest evidence for keeping PR feedback fast and for publishing only after artifact fan-in. It does not use `uv`, so it is not the dependency-manager model for this repository.

### hydrusnetwork/hydrus

The latest observed release was `v687`, with both `Hydrus.Network.687.-.Windows.-.Installer.exe` and `Hydrus.Network.687.-.Windows.-.Extract.only.zip`: [release](https://github.com/hydrusnetwork/hydrus/releases/tag/v687).

[` .github/workflows/release_win.yml`](https://github.com/hydrusnetwork/hydrus/blob/master/.github/workflows/release_win.yml) is a direct Windows release workflow triggered by `v*` tags. It uses `windows-2022`, sets up x64 Python, installs PyInstaller, runs a checked-in `.spec`, creates both an installer and an extract-only ZIP, and attaches both with `softprops/action-gh-release`. It has no dependency cache, which is a reason not to copy its install strategy unchanged. Unlike many simpler workflows, its checkout, setup-python, and release-action references are full SHA pins with trailing `# vX` comments; it is a good pinning precedent.

### vietanhdev/anylabeling

The latest observed release was `v0.4.43`, with separate CPU and GPU Windows `.exe` assets: [release](https://github.com/vietanhdev/anylabeling/releases/tag/v0.4.43).

Specific workflow evidence:

- [`.github/workflows/release.yml`](https://github.com/vietanhdev/anylabeling/blob/main/.github/workflows/release.yml) triggers on `v*.*.*`, runs a reusable test job before release creation, builds on a Linux/Windows matrix, runs PyInstaller on Windows, verifies the frozen application stays alive, and attaches the renamed Windows executables with `softprops/action-gh-release`.
- [`.github/workflows/tests.yml`](https://github.com/vietanhdev/anylabeling/blob/main/.github/workflows/tests.yml) is a separate matrix test workflow for push/tag/PR events and uses `actions/setup-python` with `cache: pip`.

These files use version tags such as `actions/checkout@v4`, `actions/setup-python@v5`, and `softprops/action-gh-release@v2`, without immutable SHAs. They are useful for job ordering and smoke-test ideas, but they do not meet this project's supply-chain requirement.

AnyLabeling demonstrates the useful release gate—tests before publication—and a post-freeze launch smoke test. Its release workflow uses Conda rather than uv, so it is evidence about release ordering and asset validation, not a dependency setup to copy.

### angr/angr-management

The latest stable observed release was `v9.3.4`, with Windows installer and ZIP assets: [release](https://github.com/angr/angr-management/releases/tag/v9.3.4).

Specific workflow evidence:

- [`.github/workflows/pyinstaller-build.yml`](https://github.com/angr/angr-management/blob/master/.github/workflows/pyinstaller-build.yml) uses `astral-sh/setup-uv`, builds on `windows-2022`, uploads the Windows artifacts, then has a separate `test_windows` job that downloads them and checks installation.
- [`.github/workflows/release.yml`](https://github.com/angr/angr-management/blob/master/.github/workflows/release.yml) triggers on `v*` tags (and also has a manual input for its broader release process), calls the reusable build, then runs `gh release create` with the downloaded files and the default `github.token`.
- [`.github/workflows/ci.yml`](https://github.com/angr/angr-management/blob/master/.github/workflows/ci.yml) shows the separate concerns: push to `master`, all pull requests, a reusable CI job, a PyInstaller job, and test jobs. It is more expensive than the proposed Asistencia DNI PR path, but its artifact-install test is a useful pattern for the release workflow.

angr-management is the best direct precedent for using the official uv action and for testing the produced Windows package separately from building it. Its current files are mixed on pinning: `ci.yml` uses SHA-pinned checkout and setup-uv references with trailing version comments, while `pyinstaller-build.yml` still contains `actions/checkout@v4`, `astral-sh/setup-uv@v5`, and `actions/upload-artifact@v4`, and `release.yml` uses `actions/download-artifact@v4`. The proposed workflow must use the SHA-pinned form consistently, not copy those tag references.

### Dioptas/Dioptas: manual uv installation comparison

This is a smaller project than the examples above, but it is a real active PyInstaller release workflow. Its latest release contains `Dioptas_Windows.zip` and `Dioptas_0.10.0_Setup.exe`: [release](https://github.com/Dioptas/Dioptas/releases/tag/0.10.0).

Both [` .github/workflows/build_windows.yml`](https://github.com/Dioptas/Dioptas/blob/develop/.github/workflows/build_windows.yml) and the Windows job in [` .github/workflows/release.yml`](https://github.com/Dioptas/Dioptas/blob/develop/.github/workflows/release.yml) use `actions/setup-python` with `cache: pip`, then manually run `python -m pip install --upgrade pip uv`, `uv sync`, install PyInstaller, build, run the executable, and package the Windows ZIP. This is the requested real example of the manual `pip install uv` approach. Its action references are version tags (`@v4`), so it also demonstrates why the implementation must add immutable SHA pins rather than copy the file literally.

For Asistencia DNI, the official action is the better fit: [`astral-sh/setup-uv`](https://github.com/astral-sh/setup-uv) installs a pinned uv version and supports uv's cache directly. The current official documentation recommends explicitly enabling the cache and supplying dependency globs; the release workflow should use the action at a reviewed full commit SHA, pin the same uv version as `mise.toml`, and key the cache from `uv.lock` (and `pyproject.toml` as a fallback). Manual `pip install uv` works, but adds an extra bootstrap dependency and duplicates the version-pinning concern.

GitHub's current Actions documentation also supports the chosen shape: tag filters can be placed under `push.tags`, and publishing jobs can use the default token with explicit `contents: write` permission. See [workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax) and [GitHub's publishing guidance](https://docs.github.com/en/actions/tutorials/publish-packages/publish-java-packages-with-gradle).

## Failures and caveats observed during the scout

The current checked-out `main` does not contain the migration files, so the contract's advertised commands cannot be treated as passing from this worktree. The commands produced:

```text
$ ruff check .
mise ERROR No version is set for shim: ruff
Set a global default version with one of the following:
mise use -g ruff@0.16.7

$ python -m pytest -q
/home/dubu/.local/share/mise/installs/python/3.14/bin/python: No module named pytest

$ uv run --no-project pytest -q
error: Failed to spawn: `pytest`
Caused by: No such file or directory (os error 2)
```

These are checkout/tool-environment failures, not evidence that the application test suite itself fails. On the migration ref, pytest and Ruff are declared in the project metadata and the intended commands are documented as `uv run ruff check .` and `uv run pytest`. No source files were changed by this scout.

The build also has a public-network dependency: `tools/descargar_scrcpy.py` downloads scrcpy 4.1 during every clean build and rejects unexpected hashes. The release brief should treat that download and hash check as an expected external build input and preserve the current failure output if it breaks; it does not require a secret.

## What the implementation brief must specify

The follow-up implementation brief needs to specify the two workflow file names and exact event filters; full immutable SHA pins for every `uses:` entry, with trailing action-version comments and a documented update/Dependabot policy; the `main`/Python 3.12/uv-lockfile versions; the reviewed `astral-sh/setup-uv` revision and uv version; the cache key inputs; the exact fast commands; the Windows runner and locked dependency sync; the unchanged `uv run tools/build_portable.py` invocation; staging of the parent-directory ZIP; ZIP-content and size/existence checks; artifact handoff between Windows and Ubuntu; release asset naming; `vMAJOR.MINOR.PATCH` validation and reconciliation of `0.1.0` versus `1.2.0`; least-privilege `GITHUB_TOKEN` permissions; and the explicit decision that code signing, physical camera/ADB testing, and Microsoft Excel COM automation are not CI requirements.
