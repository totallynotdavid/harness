# Evidence rules

How claims are graded. Every gate, review, and case in this repo uses these words.

## Claim classes

Label every material claim: **evidence** (a line read or a command run, with the handle),
**report** (someone said so, unverified), **inference** (derived from evidence), or
**unknown**. An inference presented as evidence is the failure this exists to prevent.

Every factual claim about a mechanism carries its handle: `file:line`, or the exact
command and its output. A claim with no handle is an inference; label it as one.

## Refutation

- **Refute at the layer of the claim.** A claim about an end-to-end path survives a unit
  test of one seam. A claim about a contract survives enumerating today's callers.
- **A verification gap is not a refutation.** When you cannot check it, name the gap. If the
  platform is absent or the credential is missing, report the claim as unverified. Dropping
  it silently turns a limitation into a false negative.
- **An exemption is a claim.** Anything waved through gets verified at its own layer
  before it exempts anything. An exemption you cannot state in one sentence is a finding.
- **Model agreement does not upgrade a guess.** Two models converging is a signal about
  the models. Do not vote, do not average; go check the fact they disagree about.

## Effects

When tracing what a change causes, mark each link **observed**, **inferred**, or
**guessed**. Pull the falsifiable prediction out of the weakest load-bearing link and run
the cheapest probe that could refute it. Unprobeable links stay written down as
assumptions and travel with the work.

## New checks

- **A check is born red and green.** Red on the defect that motivated it is half. Run it
  against correct work too: a check that flags good code gets ignored, and it gets ignored
  precisely when it is right.
- **A rule harvested from one symptom inherits that symptom's direction.** State the cause
  with no symptom in it, then ask what the opposite direction looks like and whether it is
  reachable.
