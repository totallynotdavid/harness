I'll start by reading the code rules, then examine the diff.
## gate: cap-headless

Scope: `bin/cap-ask`, `bin/cap-gate`, `bin/lib.sh`, `docs/pipeline-notes.md` (406+/336-). The two `notes/classroom/local-env.gate-*.md` files that show in `git diff master` are not this branch's change — `master` moved to `2cba74c` mid-review; `git diff $(git merge-base master HEAD)` is the real change, which is the defect this diff fixes.

**Behaviour verified.** I stubbed `claude` and `codex` and drove `cap-ask` through every path: clean answer, 429 rejection (blocks the profile, writes the resume record, reports the block's own reset time), retry-and-resume, `CAP_ASK_RESUME=force` two-turn `/compact`-then-continue, resumed session that returns nothing, harness crash with stderr, non-limit `is_error`, codex success and `turn.failed`. All behaved as documented. `shellcheck` is clean. `gate_verdict` returns FAIL/PASS/UNKNOWN correctly on quoted-instruction, trailing-verdict and empty reports. No `set -e`/pipefail trap in the new `[ … ] && …` lines — each has a following statement.

The defects below are all quality, not correctness.

### 1. New comments narrate the incident, which is what the rest of this diff removes — `bin/cap-ask:183-194`, `212-216`, `221-227`; `bin/lib.sh:546`

`rules/comments.md` #13: "Do not explain how the code used to work, what used to fail… without narrating the incident that revealed it." The diff strips exactly this from ~10 existing comments, then adds it back in the new code:

- `cap-ask:214` "computing this independently here **let the message print a fabricated time** that disagreed with the block `profile_block` set"
- `cap-ask:225` "Leaving it in place **wedged** cap-ask into resuming the same dead session and failing the same way forever, with nothing short of deleting the file by hand to break the loop"
- `lib.sh:546` "diff-only fingerprints **stayed constant** while deliverable (new files) changed underneath"
- `cap-ask:183-194` — 12 lines of comment on a 12-line expression, carrying "two real 55/49-turn sessions: cumulative gives 274%/267%". `rules/comments.md` #15/#16: a measurement from two sessions is not a constraint the code depends on, and length past a few lines is a signal to look at the code.

Failure: the next comment pass reads the file as already-clean and leaves them, so the rule silently stops applying to the newest code in the repo.

### 2. `diff_base` is introduced but not applied at the two sites it names — `bin/lib.sh:533`, `bin/cap-check:45-46`, `bin/cap-cleanup:16`

The helper's own comment says "`bin/cap-check` computes the same thing for the same reason," and `cap-check:45-46` / `cap-cleanup:16` still hand-roll `git merge-base … || fallback`. Three copies now, with a comment asserting they agree and nothing enforcing it (`rules/comments.md` #9, #10). Failure: a later change to how the diff base is chosen fixes `cap gate` and silently leaves `cap check` and `cap cleanup` on the old rule, which is the same class of disagreement `owns_regex` already recorded.

### 3. The modelUsage-picking expression exists three times — `bin/lib.sh:1077-1080`, `1097-1099`; `bin/cap-ask:200-202`

`usage_write` computes `$picked` once to get `model_id` for the display lookup, then re-inlines the identical `map(select(contains($model))) | .[0] // max_by(contextWindow)` in the record-building `jq` to get `$mu`. `cap-ask`'s `ctx_pct` carries a third copy. The two in `usage_write` must agree or `model_id` and the record's own `model_id` describe different entries. Failure: a fix to the picker applied to one copy produces a usage record whose `model_id` and `model` come from different models.

### 4. Comments that restate the code or make a claim the code does not support — `bin/lib.sh:121`, `136-137`, `61`

- `:121` "Recorded per commit **to prevent** fan-out from reinventing separate configs." Nothing prevents it — `verified_is` is a query, and `cap-spawn:84` is the only reader. The comment sends a reader looking for enforcement that is not there.
- `:136-137` "Read from state/peaks or fall back to `CAP_MIN_FREE_MB`" restates the four lines below it (`rules/comments.md` #3, #14). The rewrite kept the mechanics and dropped the reason the file exists (measure the cost, do not guess it), inverting #4.
- `:61` "One repo needs three installers running together" — a fact about one machine's current registry, not a constraint (`rules/comments.md` #9).

### 5. `state/usage` is left unswept, on a justification that fails under a worktree `CAP_HOME` — `bin/cap-ask:56-58`

The comment says `state/usage` needs no sweep because `cap-statusline` prunes it daily. `cap-statusline` derives its own `CAP_HOME` from its install path — here `/home/dubu/git/captain`, per `~/.claude/settings.json` — so it only ever prunes that checkout. Any `bin/cap-*` run from a worktree (which is how Captain develops itself) has `CAP_HOME` set to the worktree, and `usage_write` now drops one `<session>.json` there per call with nothing to remove it. Already observable: this worktree's `state/usage/` holds 14 orphaned records from today, oldest 01:08, while the checkout's holds 118 that are being pruned normally. The `find … -mtime +7` two lines below covers `state/ask` and `state/ask-resume` but not this.

### Minor

- `cap-ask:150` builds the die message as `"${errors:+ $errors}… See $jsonl."` — with `errors` set the text reads `ran out See /…`, missing a separator.
- `new_uuid` (`lib.sh:27`) has no failure path: on a host with neither `uuidgen` nor `/proc/sys/kernel/random/uuid`, `sid=$(new_uuid)` fails under `set -e` and `cap ask` exits 1 with no message.

GATE: FAIL
