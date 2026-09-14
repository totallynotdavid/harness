# Working rules

## Write plainly

Use short sentences. Name the subject. Cut filler and repeated context.
Prefer direct code and direct prose.

## Work

Investigate the repository, its history, and its documentation before asking
for facts they can answer. State the decision you made so it can be corrected.
Ask only when the repository cannot settle the choice.

Keep each function responsible for one thing. Keep side effects at explicit
boundaries. Put shared state behind the module that owns it. Add dependencies
through the project's package manager.

## Verify

Use the real test suite and one direct check of the behavior you changed. Show
the output that proves a failure. Treat an unverified claim as unknown.

## Comments and documentation

Comments preserve local knowledge that names and structure cannot express:
invariants, external behavior, constraints, or a non-obvious decision. They do
not narrate control flow or history.

Put workflow and subsystem explanations in the document responsible for them.
Keep one source of truth for each rule. Read rules/comments.md before a comment
cleanup and the focused document before changing a documented contract.

## Commit

Follow the repository's commit rules. Never add an AI credit, session link, or
Co-Authored-By trailer unless the repository explicitly requires it.
