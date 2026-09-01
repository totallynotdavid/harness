---
name: shape
description: Turn a fuzzy request into one shaping note - requirements crossed against candidate shapes, with an explicit spike for every real unknown. Use before building anything whose consequences the captain owns, and before writing an agent brief for non-trivial work.
---

# Shape

A shaping note is one markdown file that makes a decision defensible. It exists to stop
you building the wrong thing confidently.

Write it to `notes/<project>/<slug>-shape.md`.

## 0. Does this fire

Shape when the request has more than one plausible solution, or when getting it wrong is
expensive. Skip when the mechanism is determined, and say so in one line.

**Complete when:** the shaping started with a reason, or the skip has one.

## 1. Requirements

Number them `R1..Rn`. A requirement is testable: something you could later point at and
say it holds or it does not. Drop anything you cannot phrase that way.

Mark each one:

- **known**: you can settle it from the repo, the docs, or the captain's stated intent.
- **spike**: you genuinely cannot, and guessing would be inventing a fact.

**Complete when:** every requirement is testable and labelled.

## 2. Spikes

A spike is a bounded research task, not a hedge. For each one, state the question and how
it gets answered:

- reading this codebase -> do it now with a read
- an external library, API, or version -> `context7` or `WebSearch`
- something that must be measured -> a throwaway script, or `cap spawn <slug> <project> --scout`

Resolve every spike before the table. A shaping note that ships with an open spike is a
guess wearing a table.

**Complete when:** every spike is answered with a handle, such as a line read or a command
run, or is escalated as the finding.

## 3. Shapes

Two to four candidate solutions, `A..D`. For each: the approach in one line, what it
costs, what it forecloses. Include the boring one. Include "do nothing" when it is real.

**Complete when:** the shapes differ in mechanism, not just in wording.

## 4. The cross

| | A | B | C |
|---|---|---|---|
| R1 | ✓ | ✗ | ~ |

Then, in three lines: the pick, the requirement that decided it, and what the pick gives
up. If two shapes tie, name the evidence that would break the tie and go get it.

**Complete when:** the cross is binary: every cell decided, every ✗ carrying its failure
note.

## Auto-shape (MVP mode)

When the captain is exploring and owns nothing yet: make the obvious calls yourself,
resolve spikes rather than asking, keep the table to requirements you actually need, and
end with something demonstrable. Say which decisions you made on their behalf.

## Signal

A table that completes with no open spike usually implements in very few prompts. One
that keeps sprouting spikes is telling you the request is not understood yet: that is
the finding. Report it rather than building through it.
