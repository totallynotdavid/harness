# GitButler oplog/undo

`gitbutler-oplog` is the functioning legacy engine. `but-oplog` is a newer
wrapper/sketch that delegates to it (`Cargo.toml:35-36`; `crates/but-oplog/src/lib.rs:48-53,81-131`).

1. **Snapshot contents.** A snapshot is a root Git tree, not merely branch
   SHAs. Its documented shape includes `index`, `index-conflicts`,
   `target_tree`, `conflicts`, `project_meta.toml`, `virtual_branches.toml`,
   `virtual_branches/<id>/...`, and `worktree`; ad-hoc checkouts also get
   `checkout/{ref,commit}` (`crates/gitbutler-oplog/src/oplog.rs:115-138`).
   The index tree preserves staged entries and the conflict stages
   (`crates/gitbutler-oplog/src/oplog.rs:411-459`). The worktree tree captures
   tracked, modified, and currently untracked files: it calls `create_wd_tree(0)`
   (`crates/gitbutler-oplog/src/oplog.rs:902-907`), where zero means
   no untracked-size limit (`crates/but-core/src/repo_ext.rs:261-307`).
   Virtual-branch TOML stores metadata and branch heads; branch subtrees store
   commit data and trees, while the managed workspace commit is stored
   separately (`crates/gitbutler-oplog/src/oplog.rs:835-932`). It does not
   enumerate every repository ref.

2. **Storage.** The root tree is embedded in a Git snapshot commit. The commit
   message carries `SnapshotDetails` (`crates/gitbutler-oplog/src/entry.rs:27-43`),
   and commits form a parent-linked oplog
   (`crates/gitbutler-oplog/src/oplog.rs:940-977`). The current head is a small TOML
   file, `Oplog { head_sha, modified_at }`, at
   `project_data_dir/operations-log.toml`
   (`crates/gitbutler-oplog/src/state.rs:25-37,48-87`), normally
   under `.git/gitbutler` (`crates/but-core/src/repo_ext.rs:55-71`). A fake
   `refs/heads/gitbutler/target` plus its reflog keeps oplog commits reachable
   without showing an oplog branch (`reflog.rs:37-55`). SQLite is not the
   snapshot store: `but.sqlite` is separate (`crates/but-db/src/handle.rs:9,73-75`);
   its `butler_actions` table only records `snapshot_before`/`snapshot_after`
   OIDs (`crates/but-db/src/table/butler_actions.rs:11-24,48-68`).

3. **Undo.** Restore is substantially more than `git reset`: it checks out the
   stored worktree, restores conflicts, recreates missing commit objects,
   repoints workspace/virtual-branch/additional refs, restores metadata and
   project config, resets the index (including conflict stages), and restores
   HEAD’s checkout identity (`crates/gitbutler-oplog/src/oplog.rs:1053-1239`).
   It first captures the pre-restore state and then appends a restore snapshot
   (`crates/gitbutler-oplog/src/oplog.rs:1038-1051,1241-1275`).

4. **Cost.** It is Git-object-deduplicated, but not just a cheap ref read:
   snapshot preparation walks the worktree/index, hashes changed content, and
   writes trees/blobs plus virtual-branch commit data
   (`crates/gitbutler-oplog/src/oplog.rs:784-907`;
   `crates/but-core/src/repo_ext.rs:272-307`).
   Cost therefore grows with changed files and stack history. The wrapper’s
   intended lifecycle is prepare before the mutation and commit only after
   success (`crates/but-oplog/src/lib.rs:86-131`).

5. **Bash equivalent.** For Captain’s branch-stack safety net, write
   `git for-each-ref` output for the relevant refs, including absent/present
   names, to a timestamped file; undo with `git update-ref` (and delete refs
   absent from the file). This captures GitButler’s essential snapshot idea for
   ref-only operations, but omits worktree, index, conflict files, metadata,
   checkout identity, and missing-object preservation. That narrower scope is
   appropriate if Captain promises only to undo ref rewrites.
