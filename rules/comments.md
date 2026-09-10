# Comment rules

This is the last line of defense, not the standard. The standard is the "Write plainly"
section of `AGENTS.md`, which every agent reads at the start of every session: an agent
implementing a change is expected to write clean comments the first time, not to leave
them for a cleanup pass. This file is the checklist `cap cleanup` works from when review
finds something that got through.

A comment earns its place by preserving intent, constraints, or tradeoffs that are not
obvious from the code itself.

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
7. Read an em dash as a signal that the sentence carries two ideas. Split it rather than
   swapping in different punctuation.
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
13. State the current contract, not the history. Do not explain how the code used to
    work, what used to fail, or what a previous version did. The commit message carries
    that. A design choice that needs defending may state the constraint it protects, in
    one or two sentences, without narrating the incident that revealed it.
14. Delete comments that duplicate what the name already says. Comment only when there is
    a non-obvious rule, boundary, or privacy constraint the name can't carry.
15. Keep examples stable. Avoid colorful examples that can go false (a specific copy
    string, a specific analytics event); use invariant wording.
16. Treat length as a signal about the code. A comment that grows past a few lines is
    usually defending a decision rather than explaining one. Read the code it sits on
    before shortening the prose: the fix is often to change the code so the comment is
    unnecessary.

## Auditing a diff's comments

1. List every changed file that can carry a comment: code, templates, config, docs
   snippets, deleted/renamed replacements, tests.
2. Scan every comment form: `//`, block comments, template comments, doc comments, shell
   comments, SQL comments, and comment-shaped user-facing text.
3. Search for em dashes. Each one marks a sentence to re-read and usually to split.
4. Mark each comment: **keep** (non-obvious intent or constraint), **rewrite** (useful but
   unclear or drift-prone), **move** (useful, wrong location), **delete** (restates code
   or labels obvious structure).
5. Check placement before wording - move a misplaced comment next to the thing it
   explains before rewriting it.
6. Before deleting a comment on a function, read the function. A comment that repeats
   the name goes; a comment that states something the body does not show stays, even
   when it opens with the name. The three that matter most are a return convention (what
   a 0 or an empty string means to the caller), a rejected alternative and why it was
   rejected, and an external quirk. Expect most deletions to be right and a minority to
   be wrong: a cleanup pass here removed nine function comments and three of them held a
   return convention or a rejected alternative.
7. Deleting is the asymmetric move. A redundant comment left in place costs a reader one
   second. A deleted comment that held the only record of why the code is shaped that way
   is gone, because the reviewer reading the diff sees a deletion and no reason to doubt
   it. When a comment is genuinely borderline, shorten it instead of removing it.
8. A file header is acceptable only when it states the file's durable responsibility. One
   explaining several unrelated details should split into local comments.
9. For any comment with a count, batch size, or limit: verify the number is a real
   constraint. If it is only the current implementation, remove it.
10. For any comment naming another file or module: check whether the relationship is
    enforced. If not, rewrite to the local responsibility or add enforcement.

## Before finishing

- No comment only repeats the code or labels markup.
- Every deleted comment was checked against the code it sat on, not just its first line.
- No comment depends on another file staying synchronized without enforcement.
- No sentence needed an em dash to hold itself together.
- Long comments are split by idea and placed near the relevant code.
- Comments use the same domain terms as the code around them.
- Comments are still accurate after the formatting or refactor pass that follows.
