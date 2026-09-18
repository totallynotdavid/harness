# Codex sessions don't get Captain's guardrails

## 0. Does this fire

Yes. More than one mechanism is plausible (chase Codex hook parity, move
enforcement out of hooks entirely, or narrow Codex's sandbox), the choice
touches a security boundary (self-dispatch, path ownership, dangerous git),
and getting it wrong either leaves a real gap or burns effort chasing a
feature that doesn't work in the installed CLI. Auto-shaped: I made the
calls below myself and ran a live spike rather than asking, since the
question ("does Codex's PreToolUse hook actually fire today") is answerable
by testing it, not by discussion.

## 1. What "codex sessions aren't using the harness" actually means

Codex is not an unintegrated harness. `config/captain.conf`, `bin/caplib.py`,
and `bin/lib/99-dispatch.sh` give it full parity for dispatch, model
selection, rate-limit reading, and turn/session tracking: `codex_session_argv`
(`bin/caplib.py:467-499`), `CODEX_HOOKS` for `SessionStart`/`Stop`
(`:333-338`), `codex_trust_hooks()` (`:377-416`), `codex_rate_limits`
(`bin/lib/99-dispatch.sh:170-191`), and `harness_ancestor_pid` treating
`claude`/`codex` identically for the self-commit/self-deliver guard
(`bin/lib/60-task.sh:26-38`, proven by `tests/test-guard-self-dispatch.sh`).
The last three commits (tab labelling, session grouping under `CAP_OWNER`)
are also harness-agnostic — `cap-launch` builds the same label for both.

The actual gap is narrower and specific: the **tool-call-level guardrails**
in `bin/hooks/` — `block-dangerous-git.sh`, `guard-project-writes.sh`,
`guard-subagent-dispatch.sh`, `guard-task-paths.sh` — only ever run as
Claude `PreToolUse` hooks. They are wired in this repo's `.claude/settings.json`
for the operator's own session, and inline via `claude_settings()`
(`bin/caplib.py:288-313`) for a dispatched task's `--owns` guard. Nothing
registers an equivalent for Codex. `caplib.py:490-494` already says so out
loud:

    warn(f"{guard_slug}: --owns is not enforced under codex; "
         "the guard is a claude hook")

So: a captain session run under Codex has no dangerous-git block, no
project-write guard, and no subagent-dispatch guard. A codex-harnessed
*task* has no path-ownership enforcement. Everything else about Codex
dispatch already works.

## 2. Requirements

- **R1** (known, currently false): the operator's own dangerous-git,
  project-write, and subagent-dispatch guards take effect when the captain's
  interactive session runs under Codex, not only Claude. Verified false —
  only `.claude/settings.json` wires these three scripts.
- **R2** (known, currently false): `--owns` has an actual effect on a
  codex-harnessed dispatched task, not just a printed warning. Verified
  false at `caplib.py:490-494`.
- **R3** (spike, resolved below): whatever mechanism is chosen must
  actually fire in the Codex build Captain launches (`codex-cli 0.149.0`),
  not merely be documented upstream.
- **R4** (known, currently true, must not regress): the harness-symmetric
  parts that already work — `harness_ancestor_pid` self-dispatch guarding,
  `CAP_OWNER` session grouping, tab labelling — keep working.
- **R5** (known, stated design intent — `NORTH.md` Principles,
  `harness-review.md` §5.0): prefer enforcement the agent can't be talked
  out of over enforcement that needs the agent, or the harness, to cooperate.
  `harness-review.md` §2.3 is the worked example of what happens when a
  guard's own escape hatch is model-writable — the same failure mode a
  hook-based Codex fix would reintroduce for a *different* harness.

## 3. Spikes

**S1 — does Codex support a Claude-style deny hook, on paper?** Read
`https://learn.chatgpt.com/docs/hooks` (the `developers.openai.com/codex/hooks`
link 308-redirects there). Yes: `PreToolUse` exists, denies via exit-code-2
+ stderr or a `permissionDecision: "deny"` JSON block, and for shell commands
the payload schema is identical to Claude's — `tool_name: "Bash"`,
`tool_input.command`. That means `block-dangerous-git.sh` and
`guard-subagent-dispatch.sh`, which only branch on `tool_name`/`tool_input.command`,
would need zero changes if the hook fired. `apply_patch` (file edits) reports
`tool_name: "apply_patch"` with the patch body, not a discrete `file_path` —
`guard-task-paths.sh` and `guard-project-writes.sh` read
`.tool_input.file_path // .tool_input.notebook_path` and would find nothing
to check, so those two would fail open even if wired.

**S2 — does it actually fire in the installed CLI, using Captain's own
trust mechanism?** Resolved live, not from docs. In an isolated scratch git
repo (`/tmp/.../codex-hook-spike`, cleaned up):

1. `codex exec -c hooks.PreToolUse=[...]` with an untrusted hook command —
   the hook never ran (no payload written), and `codex exec` denying nothing,
   the `apply_patch` edit landed on disk.
2. Same test for a plain `Bash` tool call (`echo ... > shellmark.txt`) —
   same result, hook never ran, command executed.
3. Trusted the hook exactly the way `caplib.py:377-416` does — imported
   `caplib`, pointed `CODEX_HOOKS` at the spike script, called
   `codex_trust_hooks()`, confirmed the `trusted_hash` entry landed in
   `~/.codex/config.toml` — then reran both tests. Still no fire, on either
   `apply_patch` or `Bash`.
4. Control: retried the identical trust+override dance against `SessionStart`
   (the event Captain already ships in production) pointed at the spike
   script instead of the real hook command. That run hung to the 60s
   timeout instead of completing in ~10-15s like every prior call, and never
   fired either. `~/.codex/config.toml` was restored to its exact prior
   content afterward (diffed clean).

Conclusion: on `codex-cli 0.149.0`, `PreToolUse` (and an ad-hoc override of
`SessionStart` outside Captain's exact live wiring) does not reliably fire
through the mechanism Captain already uses to trust its real `SessionStart`/
`Stop` hooks. This is not a schema problem (S1); the hook plumbing itself
is not there yet in the CLI build in use.

**S3 — is this a known gap, not just something I misconfigured?**
`WebSearch` turned up two upstream issues: `openai/codex#16732`
("ApplyPatchHandler doesn't emit PreToolUse/PostToolUse... hooks only fire
for Bash tool") and `openai/codex#27833` ("PreToolUse deny... not enforced
for apply_patch — hook fires, write proceeds", filed against 0.133.0, open,
unfixed, no maintainer response as of the search). Both are narrower than
what I measured (they report the hook *firing but not denying*; I measured
it *not firing at all*, for `apply_patch` and `Bash` alike), which is
consistent with a still-rolling-out feature rather than something to file
uncritically as one exact bug number. Either way: not stable enough to build
a security boundary on right now.

## 4. Shapes

**A. Chase Codex hook parity.** Wire `PreToolUse` for Codex the same way
`SessionStart`/`Stop` are wired, rewrite the two path-reading guards to parse
`apply_patch` bodies, ship it. Cost: blocked today (S2) on a mechanism that
doesn't fire; would sit as a dead code path re-checked against every future
Codex release with no ETA.

**B. Move enforcement out of the harness's hook system, onto Captain's own
boundary.** The self-dispatch guard already does this — `cap-commit`/
`cap-deliver` refuse from inside a task's own worktree by checking process
ancestry, not by trusting a hook the agent's shell might not honor
(`bin/lib/60-task.sh:26-38`). Generalize the same shape:
  - Operator-session dangerous-git/project-write/subagent-dispatch: these
    are really "don't do X outside a `cap` command", which is enforceable
    at the `cap-*` command layer (works no matter which CLI is typing) rather
    than at the shell's tool layer.
  - Task path-ownership (`--owns`): can't be prevented pre-write without a
    working deny hook, but can be *detected* certainly and cheaply — a
    worktree-diff check against the task's `owns` globs, run in `cap verify`
    or before a gate, that fails the task hard when a codex task touched a
    path outside scope. One step later than a Claude `PreToolUse` deny, but
    certain, and nothing a violation can survive to delivery.
  Cost: doesn't stop the write mid-turn for Codex the way it does for Claude;
  buys detection instead of prevention for R2.

**C. Narrow what Codex can physically reach, instead of gating what it does.**
`codex --help` already exposes `--sandbox {read-only,workspace-write,
danger-full-access}` as a real, shipped flag — not a hook. Drop
`--dangerously-bypass-approvals-and-sandbox` for codex-harnessed tasks and
use `workspace-write` scoped to the task's own worktree: an out-of-scope
write or a destructive git command outside it becomes physically impossible,
not merely unenforced. Cost: loses some of the current bypass-everything
flexibility; legitimate work that reaches outside the worktree (shared
caches, project tooling) needs a widened case by case, same tax
`CAP_ALLOW_PROJECT_WRITE`/`CAP_ALLOW_DANGEROUS_GIT` already pay for Claude.

**D. Do nothing now; log it.** Leave the printed warning as the only
signal. Cost: the gap in R1/R2 persists silently for anyone who runs the
captain session itself under Codex, or dispatches a codex task with `--owns`.
Cheapest, fully reversible.

## 5. The cross

|    | A | B | C | D |
|----|---|---|---|---|
| R1 | ✗ blocked by S2 | ✓ command-layer, harness-blind | ~ stops writes/git, not subagent-dispatch (not a filesystem op) | ✗ |
| R2 | ✗ blocked by S2 | ~ detects at verify/gate, not at write | ✓ sandbox makes out-of-scope writes impossible | ✗ |
| R3 | ✗ | ✓ uses only what's already proven live (process ancestry, git diff) | ✓ `--sandbox` is a shipped flag, not a hook | n/a |
| R4 | ✓ untouched | ✓ untouched | ✓ untouched | ✓ untouched |
| R5 | ✗ still needs the harness to cooperate | ✓ structural | ✓ structural | ✗ advisory only |

**Pick: B for the operator-session guards and the general shape, C for
task-level path ownership specifically.** R3 is the decider — A is the only
shape that fails outright, on evidence gathered by testing it rather than
reading about it. B and C both clear every other requirement; they're not
competing, they cover different rows best: C is strictly stronger and cheaper
than B for R2 (physical prevention via an existing flag beats detection one
step later), but C alone does nothing for R1's subagent-dispatch guard, which
isn't a filesystem operation a sandbox flag can constrain — that one needs
B's command-layer move regardless of harness.

What this gives up: no pre-write deny for Codex the instant it happens,
anywhere B is doing the work instead of C. That's a real, accepted
downgrade from what Claude gets today, not a wash — it should be named as
such if this ships, not quietly implied to be equivalent.

## 6. Not done here

This is the shaping note, not the implementation. Turning B/C into a diff
touches `bin/hooks/`, `bin/caplib.py`, `bin/cap-spawn`, this repo's own
`.claude/settings.json`, and `docs/operations.md`/`NORTH.md` — worth a brief
and a dispatched task, not a same-session edit to Captain's own security
surface.
