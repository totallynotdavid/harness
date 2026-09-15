# Comment rules

Write comments for senior maintainers. Assume the reader knows the language,
the standard library, and the repository's terminology. Explain only what the
code cannot make clear.

## Keep a comment

Keep a comment only when all of these are true:

- It states a current rule, invariant, external constraint, or deliberate
  tradeoff.
- The rule is not clear from the names, control flow, types, tests, or focused
  documentation.
- The comment is beside the exact code it governs.

The important cases are a return convention, a state transition, an ordering
requirement, a rejected alternative, or a surprising tool or protocol
constraint. If the code changes, the comment must still describe the current
contract.

## Write plainly

- Name the subject. Use a direct verb and a concrete object.
- State the rule first. State the reason only when the reason affects the
  implementation.
- Keep one idea per comment. Split unrelated constraints.
- Use the same domain terms as the code and documentation.
- Prefer a short sentence. Delete the comment when a clearer name or simpler
  structure can carry the meaning.

Avoid abstract labels such as “handle the state”, “maintain the shape”, or
“process the flow”. Name the state, data, boundary, or action instead.

## Do not preserve history in source

Do not mention incidents, previous implementations, old bugs, discovery, or
why a former version was changed. Do not write “used to”, “previously”, “after
the bug”, or similar history in a source comment. Put durable operational
context in the document that owns it. Put implementation history in the commit
message.

Do not use a comment to defend a change with a story. State the current
constraint it protects. If no current constraint remains, delete the comment.

## Do not restate the code

Delete comments that repeat:

- a function, variable, type, command, query, or visible section name;
- the next line's control flow;
- a count, batch size, timeout, or other detail the code does not enforce;
- a relationship between files or modules that no check enforces.

Do not add examples merely to make a comment colorful. Use an example only
when the syntax is easy to misread and the example states a stable rule.

## Put explanations in the right place

Keep local invariants and external API constraints in source. Move user
workflow, subsystem contracts, operational recovery, configuration, and broad
design decisions to the focused document that owns them. The document must be
reachable from the relevant entry point.

Do not leave a source comment that points to documentation and repeats it.

## Review a comment change

Read the whole changed file and its callers before editing comments. For every
changed comment, choose one action:

- keep it because it states a current rule the code does not show;
- rewrite it in direct, concrete language;
- move it to the owning document;
- delete it because the code already says enough.

Before deleting a function comment, check the function's return values,
failure paths, state transitions, and external constraints. A comment that
records one of those contracts stays, but it must be rewritten without
history or abstraction.

Run the repository comment check and read the final diff as a maintainer.
