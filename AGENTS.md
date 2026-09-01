# Working rules

<!-- Shared working rules. Repository-specific instructions belong in the repository that owns the code. -->

## Implementing

Investigate before asking. Most questions are answered by the repository, its history, or
its docs. Decide from that evidence, then state the decision so it can be overridden.
Ask only for facts the repository cannot provide. Ask before writing code around an
undecided choice.

Add dependencies through the package manager's command (`npm install`, `uv add`,
`cargo add`, and so on). Do not hand-edit the manifest.

Comments earn their place when they explain non-obvious intent, a rejected alternative, or
an external quirk. Comments must not restate code or summarize material that belongs in a
document. Use a repository comment checklist when one exists.

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

## Writing

Use short sentences. Keep one idea per sentence. Use a period, comma, colon, or parentheses
instead of an em dash. Name the subject. Cut filler that repeats context.
