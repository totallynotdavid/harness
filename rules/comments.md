# Comment rules

When a comment earns its place, and how to write the ones that do. Applies to every
agent brief and every review gate; `rules/code.md`'s one-liner is the summary this
file backs up for a full audit pass.

A comment should earn its place by preserving intent, constraints, or tradeoffs that are
not obvious from the code itself.

## Writing a comment

1. Write it after reading the code around it. Do not write a header comment from memory.
   Place it next to the code, type, function, route, or branch whose intent it explains.
2. State the invariant or decision first. Prefer "Only append watch events; progress is
   derived from reads" over "This function inserts into watch_events and then updates
   progress."
3. Remove comments that only label visible structure. Delete `Status select`, `Form`,
   `Avatar`, `Loop through rows` when the nearby code already says that.
4. Replace mechanics with reason. If a comment describes what the next line does, rewrite
   it to explain why that behavior matters, what failure it prevents, what boundary it
   protects.
5. Keep each comment to one idea. Split a comment that explains ownership, performance,
   and UI behavior at once.
6. Use short sentences. A maintainer should understand the comment on one read.
7. Use plain punctuation. No em dashes; a period, comma, colon, or parentheses instead.
8. Remove drift-prone execution details unless they are the point. Avoid "one query" or
   "two reads" unless the code depends on that exact constraint - if the detail matters,
   name the constraint it protects.
9. Avoid unenforced "keep in sync" comments. If two files must stay aligned, add a test, a
   shared source, or a validation check. Absent that, state only the local contract.
10. Use the same domain term everywhere; rewrite comments that introduce a synonym for a
    concept already named elsewhere.
11. Replace ambiguous references. Name the subject instead of "this", "that", "it", "the
    shape" when more than one is nearby.
12. Keep comments within the file's responsibility - a route comment explains input,
    response, auth, and status; a domain comment explains business rules and invariants;
    an integration comment explains provider quirks; a UI comment explains non-obvious
    state or composition.
13. Prefer the current contract over history. Explain how the code used to work only when
    that history prevents a likely regression. This does not cover a comment that
    justifies a non-obvious design choice with a concrete incident - a date, a name, a
    consequence. That comment states why the contract is shaped this way, not how it
    changed. Compress its prose if it can be tighter; never cut the facts that make the
    justification checkable.
14. Delete comments that duplicate what the name already says. Comment only when there is
    a non-obvious rule, boundary, or privacy constraint the name can't carry.
15. Keep examples stable. Avoid colorful examples that can go false (a specific copy
    string, a specific analytics event); use invariant wording.

## Auditing a diff's comments

1. List every changed file that can carry a comment: code, templates, config, docs
   snippets, deleted/renamed replacements, tests.
2. Scan every comment form: `//`, block comments, template comments, doc comments, shell
   comments, SQL comments, and comment-shaped user-facing text.
3. Search for em dashes; replace each with a period, comma, colon, or parentheses, then
   re-read the sentence.
4. Mark each comment: **keep** (non-obvious intent or constraint), **rewrite** (useful but
   unclear or drift-prone), **move** (useful, wrong location), **delete** (restates code
   or labels obvious structure).
5. Check placement before wording - move a misplaced comment next to the thing it
   explains before rewriting it.
6. A file header is acceptable only when it states the file's durable responsibility. One
   explaining several unrelated details should split into local comments.
7. For any comment with a count, batch size, or limit: verify the number is a real
   constraint. If it is only the current implementation, remove it.
8. For any comment naming another file or module: check whether the relationship is
   enforced. If not, rewrite to the local responsibility or add enforcement.

## Before finishing

- No comment only repeats the code or labels markup.
- No comment depends on another file staying synchronized without enforcement.
- No comment contains an em dash.
- Long comments are split by idea and placed near the relevant code.
- Comments use the same domain terms as the code around them.
- Comments are still accurate after the formatting or refactor pass that follows.
