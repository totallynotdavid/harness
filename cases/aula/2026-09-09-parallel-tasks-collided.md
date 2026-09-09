# Four parallel tasks collided on files nobody owned

## Ledger

| Handle | Value |
|---|---|
| Repo | `~/git/aula`, created this session, base commit `f3f7d1c` |
| Tasks | `aula-schema`, `aula-design-system`, `aula-auth`, `aula-render`, spawned together, sonnet |
| Outcome | 98 tests pass in isolation. Four branches do not compose. |
| Conflicting files | `package.json`, `vitest.config.ts`, `.env.example`, `pnpm-lock.yaml` |
| Probe | Applied all four patches to a scratch `integration` branch. Three of four reported conflicts; markers left in the four files above. **evidence** |
| Second probe | `git rebase master` in `~/.cap-work/aula-schema` after landing design-system: `CONFLICT (content): Merge conflict in pnpm-lock.yaml`, `UU package.json`. Aborted. **evidence** |
| Landed | `aula-design-system` only, 5 commits, merged to master. |
| Remediation | `aula-integrate` spawned to merge the remaining three and resolve the fractures. |

## What went wrong

Three structural fractures, all downstream of one planning error.

1. **Two Drizzle setups against one database.** `aula-schema` built a root
   `drizzle.config.ts` globbing `layers/*/shared/schema.ts` with migrations in `./drizzle`.
   `aula-auth` independently built `layers/auth/drizzle.config.ts` with its own schema
   path, its own migrations directory, and its own client opening its own connection. Two
   migration journals against one database means no single ordered history, so a foreign
   key from a domain table to a user account has no guaranteed ordering. **evidence**: both
   config files read directly.
2. **Two `grade-to-words` implementations**, 35 and 45 lines, differing.
   `diff` reports them non-identical. **evidence**
3. **`layers/auth/app/pages/panel/index.vue`** puts `/panel`, the secretariat console
   route, inside the auth layer. **evidence**

## Why the gates did not catch it

A gate could have caught it, and the gate is the brief.

The captain's brief assigned ownership by **feature layer** and left the repository root
unassigned. `package.json`, `vitest.config.ts`, `.env.example` and `tsconfig.json` belonged
to no task, so three tasks each invented an answer. Layer boundaries held perfectly. The
root had no boundary to hold.

Two specific misses inside that:

- Every task was permitted to run `pnpm add`, which mutates `package.json` and
  `pnpm-lock.yaml`. Those are global files. Four writers, no owner.
- `grade-to-words` was known to be shared **at briefing time**. The render brief literally
  said "otherwise write your own and note the duplication." That is a decision deferred
  into the work rather than made during planning, and it produced exactly the duplicate it
  predicted.

No gate could have caught it downstream either: `cap check` compares one worktree against
the base, so it cannot see two branches disagreeing. Nothing in the pipeline merges
speculatively.

## Edits made

The captain's correction was that this belongs in the pipeline, not in prose: a skill
section is advice an agent can ignore, and the same miss would recur. Two deterministic
gates were added instead.

- **`bin/cap-check`: a `collisions` section.** For every other live task in the same
  project, it computes that task's changed set and reports the intersection with this
  one's, incrementing `findings` so the exit code fails. Verified against the live state:
  `cap check aula-schema` names `aula-auth` colliding on exactly `.env.example`,
  `package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `tsconfig.json`, which is the
  defect precisely. A landed task self-clears, since its diff against the base is empty
  once merged. **evidence**
- **`bin/cap-land`: a trial merge before touching the base.** `git merge-tree
  --write-tree --name-only` runs the merge in memory and the land is refused with the
  conflicted paths named. Verified: `cap land aula-schema` exits 1 reporting
  `package.json`, `pnpm-lock.yaml`, `vitest.config.ts`, and master is untouched.
  **evidence**
- `.claude/skills/crew/SKILL.md`: reduced to the half a gate cannot enforce, which is
  planning. It now points at the two gates rather than restating them.

### Two bugs found in the gates themselves while testing them

Worth recording, because both are the failure mode the gates exist to prevent.

1. **The land precheck died silently.** `bin/lib.sh` sets `set -euo pipefail`, and
   `git merge-tree` exits 1 when it finds conflicts, so the command substitution killed
   the script with no output and exit 1. A gate that refuses correctly but says nothing is
   indistinguishable from a broken one. Fixed by swallowing the status deliberately, with
   a comment saying why.
2. **The collision check hit the stale-base false positive** that `docs/pipeline-notes.md`
   already warns about. It diffed against the base *tip*, so after `aula-design-system`
   landed, every file in that merge looked like a change by every other task: 28 false
   positives on the first run. Fixed by diffing from the merge base.

## Also found

The repository has no linter, no formatter, no CI, and no dead-code check. Four branches
reached "done" without anything discovering they do not merge. Compared against
`npmx-dev/npmx.dev` (15 workflows, eslint, knip, renovate, Lighthouse gates for
accessibility and performance in both themes) and `hirotaka/pragmatic-nuxt` (3 workflows),
this is the largest remaining gap and it is what let the collision stay invisible.
