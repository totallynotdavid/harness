#!/usr/bin/env python3
"""test-turn - assert how a dispatcher reads a finished turn, across payload shapes.

Every case here is a turn shape a harness produced live or documents: an
answer in last_assistant_message, a turn whose final message was a tool call,
an account rejection, a codex turn that failed without its Stop hook. Each
must read as what it is. A misread is a confident wrong answer, not a crash.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BIN = os.path.join(ROOT, "bin")

# A scratch Captain, so profile blocks and resume records never land in the
# real state/ a captain reads.
scratch = tempfile.mkdtemp()
os.makedirs(os.path.join(scratch, "config"))
os.symlink(BIN, os.path.join(scratch, "bin"))
shutil.copy(os.path.join(BIN, "..", "config", "captain.conf"), os.path.join(scratch, "config"))
os.environ["CAP_HOME"] = scratch
sys.path.insert(0, BIN)
import caplib  # noqa: E402

failures = []


def check(name, got, want):
    if got != want:
        failures.append(f"{name}: got {got!r}, want {want!r}")


def jsonl(path, entries):
    with open(path, "w") as fh:
        for e in entries:
            fh.write(json.dumps(e) + "\n")


def claude_msg(mid, blocks, usage=None, ts="2026-09-13T10:00:05Z"):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "content": blocks, "usage": usage or {}}}


def raises(fn):
    try:
        fn()
    except Exception as e:  # noqa: BLE001
        return type(e).__name__
    return None


# 1. The answer is last_assistant_message when it carries text.
check("stop answer", caplib.turn_answer("claude", {"hook_event_name": "Stop", "last_assistant_message": "PONG"}), "PONG")

# 2. A turn ending on a tool call has an empty message. The transcript's last
# text of THIS turn is the answer, never an earlier turn's text.
t = os.path.join(scratch, "claude.jsonl")
jsonl(
    t,
    [
        {"type": "user", "message": {"content": "first question"}},
        claude_msg("m1", [{"type": "text", "text": "answer to the first question"}]),
        {"type": "user", "message": {"content": "second question"}},
        claude_msg("m2", [{"type": "text", "text": "the real second answer"}]),
        claude_msg("m3", [{"type": "tool_use", "name": "Bash", "input": {}}]),
        {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}},
        claude_msg("m4", [{"type": "tool_use", "name": "Bash", "input": {}}]),
    ],
)
check("tool-call fallback", caplib.turn_answer("claude", {"last_assistant_message": "", "transcript_path": t}), "the real second answer")
jsonl(
    t,
    [
        {"type": "user", "message": {"content": "q1"}},
        claude_msg("m0", [{"type": "text", "text": "an earlier turn's answer"}]),
        {"type": "user", "message": {"content": "q2"}},
        claude_msg("m1", [{"type": "tool_use", "name": "Bash"}]),
    ],
)
check("no text this turn", caplib.turn_answer("claude", {"last_assistant_message": None, "transcript_path": t}), "")

c = os.path.join(scratch, "codex.jsonl")
jsonl(
    c,
    [
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "q"}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "codex answer"}]}},
        {"type": "response_item", "payload": {"type": "function_call", "name": "shell"}},
    ],
)
check("codex fallback", caplib.turn_answer("codex", {"last_assistant_message": "", "transcript_path": c}), "codex answer")

# 3. An account rejection is a session limit, never an answer. Any other
# StopFailure is a harness error. A plain Stop classifies as nothing.
check("rate_limit", raises(lambda: caplib.classify({"hook_event_name": "StopFailure", "error": "rate_limit"})), "SessionLimit")
check("model_not_found", raises(lambda: caplib.classify({"hook_event_name": "StopFailure", "error": "model_not_found"})), "CapError")
check("plain stop", raises(lambda: caplib.classify({"hook_event_name": "Stop", "last_assistant_message": "API Error: Rate limit reached"})), None)

# 4. Token counts are exact: one message written as several transcript lines
# counts once, and a message from before the dispatch started counts never.
jsonl(
    t,
    [
        claude_msg("old", [], {"input_tokens": 999, "output_tokens": 999}, ts="2026-09-13T09:00:00Z"),
        claude_msg("m1", [{"type": "thinking"}], {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 7}),
        claude_msg("m1", [{"type": "text"}], {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 7}),
        claude_msg("m2", [{"type": "text"}], {"input_tokens": 1, "output_tokens": 2}),
    ],
)
since = caplib.parse_iso("2026-09-13T10:00:00Z")
check("claude tokens", caplib.claude_tokens(t, since), {"input": 11, "output": 7, "cache_creation": 7, "cache_read": 100})

# 5. A codex turn that fails ends without a Stop hook; its rollout says so,
# once per failure.
jsonl(
    c,
    [
        {"type": "event_msg", "payload": {"type": "task_complete", "error": None}},
        {"type": "event_msg", "payload": {"type": "task_complete", "error": {"message": "model is not supported"}}},
    ],
)
turn_dir = tempfile.mkdtemp(dir=scratch)
with open(os.path.join(turn_dir, "session.start"), "w") as fh:
    json.dump({"transcript_path": c}, fh)
session = caplib.Session(harness="codex", pane="-", tab="-", turn_dir=turn_dir, label="lint")
check("codex error", caplib.codex_turn_error(session), "model is not supported")
check("codex error once", caplib.codex_turn_error(session), None)

# A codex session that exits after a failed turn reports that failure, not a
# bare exit.
exit_dir = tempfile.mkdtemp(dir=scratch)
with open(os.path.join(exit_dir, "session.start"), "w") as fh:
    json.dump({"transcript_path": c}, fh)
open(os.path.join(exit_dir, "exited"), "w").close()
session = caplib.Session(harness="codex", pane="-", tab="-", turn_dir=exit_dir, label="lint")
check("codex error then exit", raises(lambda: caplib.wait_turn(session, max_wait=5)), "TurnFailed")

# A turn that ends before launch() returns is still the turn wait_turn reads.
# This herdr finishes the turn inside `pane run`, the fastest a turn can be.
fake = tempfile.mkdtemp(dir=scratch)
with open(os.path.join(fake, "herdr"), "w") as fh:
    fh.write(
        "#!/usr/bin/env bash\n"
        'case "$1 $2" in\n'
        """  "tab create") echo '{"result":{"root_pane":{"pane_id":"p1"},"tab":{"tab_id":"t1"}}}' ;;\n"""
        """  "pane run") d=$(dirname "${4#bash }"); echo '{"session_id":"fast"}' >"$d/1.json" ;;\n"""
        "esac\n"
    )
os.chmod(os.path.join(fake, "herdr"), 0o755)
saved_path = os.environ["PATH"]
os.environ.update(PATH=fake + os.pathsep + saved_path, HERDR_ENV="lint")
fast = caplib.launch(scratch, "lint", ["claude"], tempfile.mkdtemp(dir=scratch))
check("fast turn", (raises(lambda: caplib.wait_turn(fast, max_wait=3)), fast.session_id), (None, "fast"))
os.environ["PATH"] = saved_path

# herdr's done is idle no client has looked at. A session herdr reports
# either way, with no turn file, is reported, not waited out.
done_herdr = tempfile.mkdtemp(dir=scratch)
with open(os.path.join(done_herdr, "herdr"), "w") as fh:
    fh.write("#!/usr/bin/env bash\n" """[ "$1 $2" != "agent get" ] || echo '{"result":{"agent":{"agent_status":"done"}}}'\n""")
os.chmod(os.path.join(done_herdr, "herdr"), 0o755)
os.environ["PATH"] = done_herdr + os.pathsep + saved_path
caplib.IDLE_GRACE = 0
quiet = caplib.Session(harness="claude", pane="p1", tab="t1", turn_dir=tempfile.mkdtemp(dir=scratch), label="lint")
check("done without a turn", raises(lambda: caplib.wait_turn(quiet, max_wait=30)), "TurnLost")
os.environ["PATH"] = saved_path

# The hook command still finds session-event.sh when Captain's path has a
# space in it, since the harness runs the command through a shell.
spaced = os.path.join(scratch, "cap home")
os.makedirs(spaced)
shutil.copy(caplib.EVENT_HOOK, spaced)
event_dir = tempfile.mkdtemp(dir=scratch)
for command in (caplib.TURN_COMMAND, caplib.START_COMMAND):
    hook_env = dict(os.environ, CAP_SESSION_HOOK=os.path.join(spaced, "session-event.sh"), CAP_TURN_DIR=event_dir)
    subprocess.run(["sh", "-c", command], input=b'{"session_id": "spaced"}', env=hook_env, check=False)
check("spaced hook path", (len(caplib.turn_files(event_dir)), os.path.exists(os.path.join(event_dir, "session.start"))), (1, True))

# 6. Captain seeds codex's hook trust with the hash codex itself records.
# This pair was written by codex 0.153.4 when a user trusted a Stop hook.
observed = "/tmp/claude-1000/-home-dubu--cap-work-plan-remainder/03c0cb29-8d67-462f-9896-1867f6734229/scratchpad/probe/hook.sh /tmp/claude-1000/-home-dubu--cap-work-plan-remainder/03c0cb29-8d67-462f-9896-1867f6734229/scratchpad/probe/out"
check("codex trust hash", caplib.codex_hook_hash("stop", observed), "sha256:2719a803c368f17657a0bccae53c32e931ce76cc0f432997511599a43fbd0e46")

# 7. A session limit blocks the profile and leaves a record this exact call
# can resume.
subprocess.run(["bash", "-c", "mkdir -p \"$CAP_HOME/state/usage\""], check=True)
profile = caplib.Profile("haiku", "claude", "haiku", "-")
session = caplib.Session(harness="claude", pane="-", tab="-", turn_dir=turn_dir, label="lint", session_id="s-1")
with open(os.path.join(caplib.USAGE, "s-1.json"), "w") as fh:
    json.dump({"at": caplib.now(), "ctx_pct": 12, "five_hour": {"pct": 100, "resets_at": caplib.now() + 600}}, fh)
check("limit raises", raises(lambda: caplib.limit_reached(profile, session, "k1", None, None, "429")), "CapError")
check("limit blocks", caplib.lib_ok("profile_blocked", "haiku"), True)
check("limit resumable", caplib.pending_resume(profile, "k1")[0], "s-1")

# Two reviewers with the same prompt on the same profile are two calls: a
# limit that interrupts one leaves nothing the other resumes.
key_a = caplib.resume_key(profile, "/tree", "review this", "gate-A-t")
key_b = caplib.resume_key(profile, "/tree", "review this", "gate-B-t")
raises(lambda: caplib.limit_reached(profile, session, key_a, None, None, "429"))
check("reviewer keys", (caplib.pending_resume(profile, key_a)[0], caplib.pending_resume(profile, key_b)[0]), ("s-1", None))

shutil.rmtree(scratch, ignore_errors=True)
if failures:
    for f in failures:
        print(f"test-turn: {f}", file=sys.stderr)
    sys.exit(1)
print("test-turn: turn payloads, fallbacks, failures and token counts read as what they are")
