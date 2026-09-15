# Commit rules

How a commit message must read. Applies to every commit, captain or agent, in any repo.

## Message template

Use only a subject for a small or mechanical change:

```text
rename: move the status helper
```

Add a description when the change spans several files, changes behavior, or needs context:

```text
rules: keep commit messages consistent

Why: Make the commit pipeline deterministic.

The pipeline writes the final message from the commit plan.
```

The description can contain as many paragraphs as the change needs. Keep each line easy
to read, but do not pad the message to satisfy a character count.

## Subject

- Start with a lowercase ASCII word and use the imperative present tense: `add`, `fix`,
  `remove`, not `Added`, `Fixed`, or `Removed`.
- An optional area prefix is allowed when it names the part of Captain being changed. Keep
  it lowercase and start the description after the colon with a lowercase word, such as
  `status: render usage`.
- Do not use a conventional-commit type prefix such as `feat:`, `fix:`, or `chore:`.
- Do not end the subject with a period.
- A subject that needs several clauses usually describes several changes. Split the work
  instead of hiding multiple purposes in one line.

## Description

- Omit it for a small, obvious, or pure rename change.
- If present, the first line must be `Why: <reason>` with a non-empty reason.
- Explain motivation, constraints, tradeoffs, or behavior the diff cannot show.
- Do not restate the changed files or narrate the implementation.

`cap commit` records groups and complete messages before writing history. Each changed path
must belong to one group. Captain stages each group and writes its planned message. `cap
deliver` checks the resulting commits against the plan.

## Style

No em dashes. Short sentences. No padding, no restating the diff in prose.
