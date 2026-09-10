

● Clean. Shellcheck finds nothing beyond an info-level unresolved source path. Let me check a couple more targeted things: whether codex_limit_reached still works given
  jsonl now stores raw output the way it expects, and confirm CAP_USAGE_DIR and mkdir -p etc. are all defined.

  Searched for 3 patterns, ran 4 shell commands

● Good, flags confirmed. Now a live smoke test of cap-ask's claude path with a trivial prompt to validate the stream-json parsing actually works end to end.

  Listed 1 directory, ran 2 shell commands

● Live smoke test confirms the headless claude path works end to end and writes a transcript. Now let me quickly test cap-gate's diff_base logic and
  gate_verdict/gate_fingerprint for real bugs by simulating them directly.

  Ran 3 shell commands

● I read rules/code.md and reviewed the full diff against master (bin/cap-ask, bin/cap-gate, bin/lib.sh, docs/pipeline-notes.md, and two notes/classroom/local-env.gate-*.md
  report files). Working tree is clean, so the committed state is the whole change.

  Methodology: read every hunk, cross-referenced every helper (profile_block, profile_block_until, diff_base, gate_fingerprint, gate_verdict, usage_write, new_uuid,
  harness_trust) to confirm nothing was left dangling by the herdr→headless rewrite, ran shellcheck -x on the three changed scripts (clean), verified the claude/codex exec
  CLI flags this code relies on (--session-id, -r/--resume, -p --output-format stream-json --verbose, codex exec --json -o/--output-last-message
  --dangerously-bypass-approvals-and-sandbox -C) actually exist via --help, live-ran bin/cap-ask sonnet 'Reply with exactly: OK' --dir /tmp end to end (succeeded, wrote a
  transcript to state/ask/), and exercised gate_verdict/diff_base/new_uuid directly in a shell to confirm their edge-case handling (stray "GATE: PASS" substrings inside
  prose, leading bullet clutter, missing uuidgen, merge-base divergence).

  No functional defects found. Two minor, non-blocking observations:

  1. bin/cap-gate:28 extracts a new shared diff_base() into lib.sh and its own comment says this is "the same distinction cap-check's diff_from makes," but
     bin/cap-check:45-46 still carries its own separate inline copy of that same logic rather than calling the new helper. Functionally identical, just an un-converted
     duplication the refactor left behind — not a bug.
  2. notes/classroom/local-env.gate-A.md and local-env.gate-B.md were updated with content that still bears the old pane-capture mechanism's artifacts (❯ prompt lines, "⏵⏵
     bypass permissions on", a live status line with ctx/5h/7d percentages, "Baked for Xm"). Those only come from an interactive herdr pane read, which this branch's whole
     point is to stop using for cap-ask. They're unrelated to this branch's subject (a different project's dev-stack review) and, going forward, don't represent what a
     cap-gate report will actually look like once this lands (plain answer text, no chrome). Harmless, but stale/misleading if kept as reference material.

  Everything else checks out: the headless cap-ask rewrite correctly handles turn-by-turn resume/compact, distinguishes a session-limit rejection from other errors via
  structured JSON fields (not string-matching), cleans up its own temp files on every exit path, prunes its own state directories, and the set -euo pipefail idioms used
  throughout (A && B, A || B, if !) are all safe against premature exit. cap-gate's new diff_from/fingerprint fix is a real, verified improvement (a sibling landing into
  base no longer poisons the reviewed diff). Documentation in docs/pipeline-notes.md accurately describes the code as written.

  GATE: PASS

✻ Churned for 5m 18s · done 9:13 AM

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Sonnet 5  |  ctx 12% used  88% left  |  in:120270 out:5  |  5h:86% 7d:42%                                                                                            /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · 4 memories recalled · ← for agents
