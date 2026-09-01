---
name: review
description: Gate a diff before it lands - deterministic checks first, then focused passes chosen by what the diff changes, then drive the feature as a user. Use before opening a PR, when asked to pre-review a change, and after an external reviewer finds something a check should have caught.
---

# Review

The goal is that external review rounds get boring: findings per round trending to zero.
Generic review is imagination sampling: each pass finds a different random subset. Checks
replace imagination wherever a check exists; judgment is spent on what is left.

Claim grading is `rules/evidence.md`.

## 1. Deterministic layer, first

```sh
cap check <slug>          # surfaces, stale identifiers, callers, siblings
cap conventions <project> # once per project, if the surface map is missing
```

These checks are cheap and deterministic within their defined patterns. Every finding is
fixed or acknowledged with a reason. Run the project's own checks too
(tests, types, lint) before spending a single model token on reading the diff.

**Complete when:** every deterministic check passes, or each finding is fixed or
acknowledged.

## 2. Model the subsystem before reading the diff

Read the diff last. Reasoning from the diff finds what the diff shows; the defects live
in what it assumes. Build the model from the code and `cases/<project>/conventions.md`:

- **Topology**: which processes exist, which stdio each owns, where output actually
  lands. A diagnostic on the wrong channel reaches a log nobody opens.
- **Consumers**: every path that applies the rule this fix touches, not just the primary
  one. Error builders and suggestion text re-derive values too.
- **Guard domain**: when the diff adds a guard, its real input domain is what the
  composed callers accept, not the arguments it inspects.

Then ask the question that finds things: **what layer does this fix assume correct and
never touch?** That named layer is a candidate finding before any pass runs.

**Complete when:** topology, consumers, and the named adjacent layer are written down.

## 3. Focused passes

Pick passes from what the diff actually changes, run each as its own pass over the whole
diff, and prefer a different family from the one that wrote it: a same-family reviewer
shares its blind spots. `cap ask <profile>` does this in one command.

**Freeze the tree while a reviewer runs.** Editing under an in-flight reviewer invalidates
its line citations and can refute findings it never saw.

A merged mega-pass dilutes every lens it carries. When the same guard fails review twice
on one class, stop imagining variants and build a differential corpus instead.

**Complete when:** each pass is run or skipped with a reason, and the adjacent layer from
step 2 is cleared or confirmed.

## 4. Drive it, then report

Build the artifact and use the shipped surface as a user would: real flags, real inputs,
real error cases, real substrate. Not the author's tests, which only assert what the
author already thought of. This is where confident-but-wrong findings die and real ones
are born.

Verify each candidate finding by reproducing it or forcing the state it claims is
reachable. A regression test counts as unwritten until it has gone red once.

The report ends with two sections that are easy to skip and shouldn't be:

- **Exemptions claimed**: each with its evidence, so the captain can veto one cheaply.
- **Issue candidates**: real defects outside this diff's scope, with the evidence already
  gathered, so they can be filed without redoing the work. Buried in a "known issues"
  paragraph, they die there.

**Complete when:** the feature was driven or each gap is named, every finding has evidence
at its own layer, and both closing sections exist.

## 5. Harvest what got past

When a human finds something the checks should have caught, that is a gate bug. Classify:

- machine-checkable -> a new surfaces line or check in `cap check`
- a project norm -> a house-norm line in `cases/<project>/conventions.md`
- reasoned from the whole system -> a **subsystem invariant** in that file, so step 2
  reconstructs the seam next time

Record the miss in that file's gate-miss ledger: date, finding, which gate missed, why,
what closed it. Then apply the two rules for new checks in `rules/evidence.md`: born red
and green, and stated in both directions.

**Complete when:** every external finding is matched to a gate that missed with the miss
explained, or captured as a new check.
