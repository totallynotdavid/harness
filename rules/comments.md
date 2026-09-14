# Comment rules

Source comments preserve knowledge that the code cannot carry through names or
structure. A comment must explain an invariant, external behavior, constraint,
or decision that a reader would otherwise miss.

## Keep the comment in source

- A local invariant protects a branch, a state transition, or an ordering rule.
- An external tool, protocol, or framework imposes a surprising constraint.
- A decision cannot be expressed by a clearer name, split function, or simpler
  control flow.

Put the comment beside the exact line, field, or branch it explains. A
function-level comment applies to the whole function. A file header names the
file's durable responsibility.

## Move the explanation to documentation

Move a comment when it describes:

- a user workflow or command sequence;
- a subsystem contract used by several files;
- operational recovery or configuration;
- a design choice whose scope is larger than the code beside it;
- history that does not change the current contract.

The document that owns the explanation must be reachable from the relevant
instruction or entry point. Do not leave a source comment that merely points
at a document and repeats its conclusion.

## Delete or rewrite

Delete comments that restate names, types, control flow, SQL, or the next line.
Delete comments that label visible sections. Replace a comment that explains
confusing code with clearer names, smaller functions, or simpler ordering.

Write the current contract. Do not describe an old implementation, a previous
failure, or how the comment was discovered. Split a comment that carries more
than one idea. Avoid examples, counts, and synchronization claims unless the
code enforces them.

## Review a change

Read the whole changed file before editing. For every comment, decide whether
the code, a focused document, or no text should carry the meaning. Check the
placement before polishing the wording. Then run the repository comment check
and read the final diff as a maintainer.
