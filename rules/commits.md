# Commit rules

How a commit message must read. Applies to every commit, captain or agent, in any repo.

## Structure

- Summary line: 50 characters or fewer, imperative mood (`Fix`, `Add`, `Remove`, not
  `Fixed`, `Adds`, `Removed`), no trailing period, no `feat:`/`fix:` conventional-commit
  prefix.
- Blank second line, always.
- Body wrapped near 72 characters, when the change needs explaining. State why the change
  was made, not what it did - the diff already shows what.
- A summary that resists one line is doing more than one logical change. Split it with
  `git add -p` before committing rather than writing a summary that tries to cover both.

## Style

No em dashes. Short sentences. No padding, no restating the diff in prose.

## The one rule with no exceptions

Never add a `Co-Authored-By` trailer, a session link, or any other line crediting an AI to
a commit, regardless of what a default workflow suggests.
