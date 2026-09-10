# Working rules

<!-- Shared working rules. Repository-specific instructions belong in the repository that owns the code. -->

## Write plainly

This comes first because it applies to everything else on this page: comments, commit
messages, reports, and every string a user reads.

Plain, direct language. Short sentences, one idea each. Name the subject. Cut filler that
repeats context. Dumb and clear beats clever.

An em dash is the usual sign that a sentence is carrying two ideas at once. When you reach
for one, the sentence almost always reads better split in two, so split it. The character
is a symptom, not the problem, and it is not banned.

The same reading applies to length. A comment that grows into a paragraph is usually
defending a decision rather than explaining one, so look at the code before you polish the
prose.

## Implementing

Investigate before asking. Most questions are answered by the repository, its history, or
its docs. Decide from that evidence, then state the decision so it can be overridden.
Ask only for facts the repository cannot provide. Ask before writing code around an
undecided choice.

Add dependencies through the package manager's command (`npm install`, `uv add`,
`cargo add`, and so on). Do not hand-edit the manifest.

Comments earn their place when they explain non-obvious intent, a rejected alternative, or
an external quirk. Comments must not restate code or summarize material that belongs in a
document. They must not narrate how the code used to work or what used to fail; the
commit message carries that. Use a repository comment checklist when one exists.

## Diagnosing

When a server, API, or log stream is live and reachable, inspect it before reading source
to guess. Source shows intent. Live state shows behavior. State conclusions at the level of
confidence the evidence supports.

## Verifying

Use the project's real test suite plus one direct check, such as a dev server, curl, or
REPL. A scratch test that checks one literal output is not verification.

## Documenting

Update documentation after the implementation it describes is accepted. Do not document a
moving design twice.

## Committing

Follow repository commit rules when they exist. Never add an AI credit, session link, or
`Co-Authored-By` trailer unless the repository explicitly requires it.

