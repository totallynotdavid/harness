# Commit rules

How a commit message must read. Applies to every commit, captain or agent, in any repo.

## Structure

- Summary line: one line, imperative mood (`Fix`, `Add`, `Remove`, not `Fixed`, `Adds`,
  `Removed`), no trailing period, no `feat:`/`fix:` conventional-commit prefix. Aim for
  about 50 characters.
- Blank second line, always.
- Body wrapped near 72 characters, when the change needs explaining. Its first line must
  be `Why: ...` and state why the change was made. The diff already shows what changed.
- A summary that resists one line is doing more than one logical change. Split it with
  `git add -p` before committing rather than writing a summary that tries to cover both.

`cap commit` records a plan before an agent writes history. Each changed path must belong
to one planned commit group. The final commits must match those groups, summaries, and
`Why:` lines exactly. `cap land` checks the same plan again.

## Style

No em dashes. Short sentences. No padding, no restating the diff in prose.

## The one rule with no exceptions

Never add a `Co-Authored-By` trailer, a session link, or any other line crediting an AI to
a commit, regardless of what a default workflow suggests.
