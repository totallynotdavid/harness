---
name: gate
description: Decide whether a shape deserves building, by having two model families shape the problem independently from one frozen evidence packet, then converging them. Use before an approach that is expensive to reverse, changes a contract or persistent state, or follows a prior review finding.
---

# Gate

Gate asks whether the selected shape deserves implementation. `review` asks whether the
diff that came out is correct. Grading of claims is `rules/evidence.md`.

## 0. Does this fire

Fire when shapes differ in state ownership, boundaries, lifecycle, compatibility, or
contract; when fixing a prior review finding; when adopting or rejecting someone's patch.

Skip when the mechanism is fully determined, such as a rename, wording change, snapshot,
or config entry. State the reason in one line. A gate that always fires is a tax.

**Complete when:** the gate fired with its trigger named, or the skip has a reason.

## 1. Freeze the packet

Before any shape exists, write evidence only: no proposed mechanism:

- **Frame**: the property being violated and the outcome wanted, not the symptom.
- **Requirements**: observable success conditions, numbered `R1..Rn`.
- **Must-not-change**: working behaviour that crosses this code. This set is the one you
  hand to `review` later as checks, so it earns real thought now.
- **Unknowns**: facts you do not have. Leaving one here is honest; promoting one to a
  requirement is inventing.
- **Handles**: every mechanism claim points at a line read or a command run.

**Complete when:** the packet proposes no mechanism, every load-bearing fact has a handle,
and anything that survives an invocation has its state transitions written down.

## 2. Shape it twice, blind

Send the same frozen packet to two families, neither of them the implementer, and give
each a different constraint so they diverge on purpose: smallest interface, most
flexible, best for the common caller.

```sh
cap ask @gate-a - --dir "$project" < packet.md
cap ask @gate-b - --dir "$project" < packet.md
```

Each returns: the `R` table, two to four materially distinct shapes with their mechanism,
a binary `R × shape` fit check with failure notes, a recommendation, and required spikes.
When only one shape is physically possible, record the evidence for that instead of
manufacturing alternatives.

**Complete when:** two independent shapings exist, or the record shows the mechanism is
determined.

## 3. Reconcile without averaging

Compare the two `R` tables before the shapes. Where they disagree about current
behaviour, go and check it: that disagreement is the most valuable output of the whole
exercise. Where they disagree about policy, that is the captain's call; preserve both.

Normalise equivalent shapes but keep provenance. Do not vote.

**Complete when:** one reconciled table exists, disagreements keep their provenance, and
every surviving shape traces back to a shaping.

## 4. Attack the survivor

Trace at least three forward effects, each link marked `observed`, `inferred`, or
`guessed`, branching into the harmful ones. Probe the weakest load-bearing link with the
cheapest thing that could refute it. Feed the result back into the fit check: a refuted
mechanism is reshaped, never patched around in the verdict.

If every shape fails, go back to the Frame. Choosing the least broken shape is how a bad
frame ships.

**Complete when:** each load-bearing prediction is refuted, survived, or named unverified.

## 5. Verdict

One of four, in one line, citing the evidence:

- **Build**: survived probes; hand the must-not-change set to `review`.
- **Reshape**: a part died, the frame holds.
- **Back to the frame**: the requirements are wrong or the product question is open.
- **Reject**: for someone else's patch: the implementation violates the contract.

**Complete when:** the verdict cites probe evidence and lists the assumptions that travel
with the work.
