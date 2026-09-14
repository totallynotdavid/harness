# Commit rules

How a commit message must read. Applies to every commit, captain or agent, in any repo.

## Subject

- Write one subject line of at most 50 characters.
- Start with a lowercase ASCII word and use the imperative present tense: `add`, `fix`,
  `remove`, not `Added`, `Fixed`, or `Removed`.
- An optional area prefix is allowed when it names the part of Captain being changed. Keep
  it lowercase and start the description after the colon with a lowercase word, such as
  `status: render usage`.
- Do not use a conventional-commit type prefix such as `feat:`, `fix:`, or `chore:`.
- Do not end the subject with a period.
- A subject that needs several clauses usually describes several changes. Split the work
  with `git add -p` instead of hiding multiple purposes in one line.

## Body

- Leave the second line blank, always.
- If a body is present, its first line must be `Why: <reason>` with a non-empty reason.
- Wrap body lines at 72 characters or less.
- Keep the body for constraints, motivation, or behavior that the diff cannot show.

`cap commit` records a plan before an agent writes history. Each changed path must belong
to one planned commit group. The plan uses the same subject and body rules. Final commits
must match the groups, summaries, and `Why:` lines exactly. `cap land` checks the plan
again.

## Style

No em dashes. Short sentences. No padding, no restating the diff in prose.

## The one rule with no exceptions

Never add a `Co-Authored-By` trailer, a session link, or any other line crediting an AI to
a commit, regardless of what a default workflow suggests.
