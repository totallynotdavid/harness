Outcome: `.github/workflows/release.yml`'s `build-windows` job successfully stages and
uploads the portable ZIP as an artifact. It currently fails at that exact step — the
build itself succeeds (confirmed: `Build portable package` and `Verify executable and
ZIP` both passed in a real run,
https://github.com/cicatnet/windows/actions/runs/35093129579), but `Stage portable ZIP`
errors:

```
##[error]Invalid pattern '../AsistenciaDNI_Portable.zip'. Relative pathing '.' and '..' is not allowed.
```

Root cause: `tools/build_portable.py` writes the ZIP one directory above the repo root
(`../AsistenciaDNI_Portable.zip`, confirmed correct and already documented in the
workflow's earlier "Verify executable and ZIP" step, which checks that same path
successfully). `actions/upload-artifact`'s `path:` input does not accept `.`/`..`
segments at all, even as part of an otherwise-valid path — this is a hard constraint of
that action, not something to work around by trying an absolute path built with `..` in
it.

Fix: before the "Stage portable ZIP" step, copy (not move — the "Verify executable and
ZIP" step already ran and passed, don't invalidate what it checked) the ZIP from
`../AsistenciaDNI_Portable.zip` into a location under `$env:GITHUB_WORKSPACE` (a `dist/`
subfolder is reasonable, or right at the workspace root if nothing collides with the
name), then point `actions/upload-artifact`'s `path:` at that in-workspace copy.

Constraints:

- Do not change what `tools/build_portable.py` does or where it writes its output — this
  is a workflow-only fix, the packaging script's parent-directory output is correct and
  already relied on by other parts of the release process.
- Keep the existing existence/size checks in "Verify executable and ZIP" as-is; just add
  the copy step after them, before the upload step.
- Same SHA-pinning requirement as every other action reference in this repo's workflows
  — you're not adding a new `uses:` entry here, just fixing a `run:`/`path:` step, so
  this should be a non-issue, but don't introduce one if you end up needing a new action.

Evidence: leave your fix uncommitted, as usual — the captain will commit, push (as a PR,
so CI runs on it first), merge, and re-tag `v1.2.0` to prove a real release run
publishes successfully end to end. Locally, you can't reproduce a Windows runner, so
your own verification is necessarily limited to reading `actions/upload-artifact`'s
actual documented path constraints (check its README/action.yml, don't guess) and
confirming the copy step's logic is correct by inspection — say so plainly in your
report rather than claiming you ran it.
