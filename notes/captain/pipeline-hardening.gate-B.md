Reviewed all 12 changed paths against `fb9bef0e...`; the worktree is clean.

Verified working:

- `mise run lint` and all configured check tasks pass.
- All changed shell scripts pass `bash -n`.
- `git diff --check` passes.
- `cap-check --repo captain` exits 0.
- Process-substitution status handling and fingerprint generation work.
- Tracked-only dirty detection behaves as intended for shared checkout handling.
- Incremental gate checkpoint logic is consistent with `gate_ready`.

No concrete defect found. A live `cap gate` run was not performed because this worktree has no task record.

GATE: PASS
