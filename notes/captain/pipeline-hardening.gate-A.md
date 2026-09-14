Looking at the code rules and reviewing the changes systematically.

**Checked:**
- Comments: Justified explanations of non-obvious intent and external constraints (e.g., process-sub failures, merge-base movement, fork-point tracking)
- Error handling: Added throughout for git commands, sed, tail, awk, process substitutions
- Function design: New `gate_fingerprint_from`, `gate_review_since`, `gate_last_commit`, `git_dirty_tracked` are focused and single-purpose
- Readability: Refactorings reduce nesting, extract variables before loops to catch failures (cap-check, cap-commit, lint-andlist, lint-dead-flag)
- Linters: Four new tools properly guard against shell patterns (dead flags, unchecked process subs, missing topo-order, task state logic)

**Verified working:**
- `gate_review_since` correctly falls back to full range when checkpoint is invalid
- Process-substitution failure capture using `pid=$!` and `wait` is correctly placed (after loop/mapfile completes)
- Early returns in `gate_review_since` handle empty trees and moved fork points
- Fingerprinting scoped to `$since` (not always full range) is correct; calling code understands the difference
- `git_dirty_tracked` vs `git_dirty` distinction: cap-land uses tracked-only (untracked tolerated), cap-verify uses full-check (must be clean)

**Defect found:**

**cap-land lines 263–266:** Redirection order is wrong.
```bash
checkout_err=$(git -C "$CAP_REPO" checkout "$CAP_BASE" 2>&1 >/dev/null) ||
```

The order `2>&1 >/dev/null` binds stderr to stdout, then redirects stdout to /dev/null. This results in:
- stdout → /dev/null (discarded)  
- stderr → pipe (captured)

This silently discards stdout while only capturing stderr. Git errors do go to stderr in practice, so it might work, but the code is fragile and backwards. Should be:
```bash
checkout_err=$(git -C "$CAP_REPO" checkout "$CAP_BASE" 2>&1) ||
```

Same issue in the merge line.

---

GATE: FAIL
