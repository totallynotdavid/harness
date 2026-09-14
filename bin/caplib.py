"""The harness-facing half of Captain.

Every agent session Captain starts runs the same way: a real interactive
session in a herdr pane, with Captain's hooks passed on its command line. A
turn ends when the harness runs the Stop hook, which drops the turn's payload
into a directory the dispatcher chose. The answer, the session id and the
transcript all come from that payload, never from the screen.

Git, worktree and task-state plumbing stays in bin/lib.sh. This module calls
into it rather than restating it.
"""

import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

BIN = os.path.dirname(os.path.realpath(__file__))
HOME = os.environ.get("CAP_HOME") or os.path.dirname(BIN)
LIB = os.path.join(BIN, "lib.sh")
TASKS = os.path.join(HOME, "state", "tasks")
USAGE = os.path.join(HOME, "state", "usage")
EVENT_HOOK = os.path.join(HOME, "bin", "hooks", "session-event.sh")

# The hook commands both harnesses run. They name no path: codex trusts a
# hook by hashing its command, so a command that differed per task or per
# Captain checkout would need trusting again on every launch. The launch
# environment supplies the path.
TURN_COMMAND = '"${CAP_SESSION_HOOK:-true}" turn'
START_COMMAND = '"${CAP_SESSION_HOOK:-true}" start'


class CapError(Exception):
    """A failure to report as `cap: <message>` and exit 1."""


class LibFailed(CapError):
    """A bin/lib.sh function failed and has already said why on stderr."""


def warn(msg):
    print(f"cap: {msg}", file=sys.stderr, flush=True)


def run_main(main):
    # A dispatcher that is stopped closes the sessions it started. Left open,
    # a review nobody will record keeps spending the account's window.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _interrupted)
    try:
        sys.exit(main())
    except LibFailed:
        sys.exit(1)
    except CapError as e:
        warn(str(e))
        sys.exit(1)
    except KeyboardInterrupt:
        close_live_sessions()
        # Not sys.exit: a reviewer thread still waiting on its turn would
        # hold the process open after its pane is gone.
        os._exit(130)


def _interrupted(signum, frame):
    raise KeyboardInterrupt


# --- bin/lib.sh ------------------------------------------------------------


def lib(func, *args, check=True):
    """Run one bin/lib.sh function and return its stdout."""
    env = dict(os.environ, CAP_HOME=HOME)
    proc = subprocess.run(
        ["bash", "-c", '. "$0"; "$@"', LIB, func, *args],
        stdout=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    if check and proc.returncode != 0:
        raise LibFailed(f"{func} failed")
    return proc.stdout


def lib_ok(func, *args):
    env = dict(os.environ, CAP_HOME=HOME)
    proc = subprocess.run(
        ["bash", "-c", '. "$0"; "$@"', LIB, func, *args],
        stdout=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        env=env,
    )
    return proc.returncode == 0


def conf(name, default=""):
    """A value from config/captain.conf, after environment overrides."""
    env = dict(os.environ, CAP_HOME=HOME)
    proc = subprocess.run(
        ["bash", "-c", '. "$0"; printf "%s" "${!1:-}"', LIB, name],
        stdout=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    return proc.stdout if proc.stdout != "" else default


def now():
    return int(time.time())


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- profiles --------------------------------------------------------------


@dataclass
class Profile:
    name: str
    harness: str
    model: str
    effort: str
    role: str = ""


def resolve_profile(spec):
    """A profile name, or @role resolved against the account's current window."""
    role = ""
    name = spec
    if spec.startswith("@"):
        role = spec[1:]
        name = lib("role_profile_or_die", role).strip()
    harness, model, effort = lib("ask_profile", name).split()
    return Profile(name, harness, model, effort, role)


def effective_effort(profile):
    """A profile's own effort wins; a role's effort fills in the harness default."""
    if profile.effort != "-":
        return profile.effort
    if not profile.role:
        return ""
    return lib("role_effort", profile.role).strip()


def check_profile(profile):
    """Refuse a profile the account cannot run before any pane opens."""
    env = dict(os.environ, CAP_HOME=HOME)
    proc = subprocess.run(
        ["bash", "-c", '. "$0"; profile_check "$1" "$2"', LIB, profile.name, effective_effort(profile)],
        stdout=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        raise CapError(f"profile '{profile.name}': {proc.stdout.strip()} (run cap models)")
    if not shutil.which(profile.harness):
        raise CapError(f"{profile.harness} is not installed")


# --- tasks -----------------------------------------------------------------


def task_field(slug, key):
    path = os.path.join(TASKS, slug, "task.env")
    try:
        with open(path) as fh:
            for line in fh:
                k, _, v = line.rstrip("\n").partition("=")
                if k == key:
                    return v
    except OSError:
        return None
    return None


def task_for_tree(directory):
    """The task whose worktree is this directory, or None."""
    want = os.path.realpath(directory)
    try:
        slugs = sorted(os.listdir(TASKS))
    except OSError:
        return None
    for slug in slugs:
        tree = task_field(slug, "CAP_TREE")
        if tree and os.path.realpath(tree) == want:
            return slug
    return None


_held_locks = {}


def task_lock(slug):
    """bin/lib.sh's task_lock, for a Python command that mutates a task.

    Re-entrant through CAP_LOCKS, so cap commit holding the lock can run
    cap ask inside the same task without refusing itself.
    """
    held = os.environ.get("CAP_LOCKS", "").split()
    if slug in held or slug in _held_locks:
        return
    d = os.path.join(TASKS, slug)
    os.makedirs(d, exist_ok=True)
    fh = open(os.path.join(d, ".lock"), "a+")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.seek(0)
        holder = fh.read().strip() or "another cap command"
        fh.close()
        raise CapError(f"{slug} is already held by {holder}")
    fh.seek(0)
    fh.truncate()
    fh.write(f"pid {os.getpid()} ({os.path.basename(sys.argv[0])}) since {time.strftime('%H:%M:%SZ', time.gmtime())}\n")
    fh.flush()
    _held_locks[slug] = fh
    os.environ["CAP_LOCKS"] = " ".join(held + [slug])


# --- launch environment ----------------------------------------------------

SCRUBBED = (
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_SSE_PORT",
    "CODEX_SANDBOX",
)


def cache_env():
    root = conf("CAP_CACHE_ROOT", os.path.expanduser("~/.cache/cap"))
    os.makedirs(root, exist_ok=True)
    return {
        "NPM_CONFIG_CACHE": f"{root}/npm",
        "YARN_CACHE_FOLDER": f"{root}/yarn",
        "PIP_CACHE_DIR": f"{root}/pip",
        "CARGO_HOME": f"{root}/cargo",
        "GOMODCACHE": f"{root}/go-mod",
        "COMPOSER_CACHE_DIR": f"{root}/composer",
    }


def launch_env_prefix(extra):
    """`env -u ... K=V` for the launch script.

    A dispatched agent never inherits Captain's own CAP_* variables (a held
    lock, a pinned session identity), only the ones this launch sets.
    """
    unset = list(SCRUBBED) + sorted(k for k in os.environ if k.startswith("CAP_"))
    argv = ["env"]
    for name in unset:
        argv += ["-u", name]
    for k, v in {**cache_env(), **extra}.items():
        argv.append(f"{k}={v}")
    return argv


def claude_settings(guard_slug):
    """Captain's hooks for one claude session, passed as --settings JSON.

    Passed on the command line, never written into the worktree, so the
    config is not a file the project could commit. The guard runs from
    Captain's own checkout, outside the reach of the agent it constrains.
    """
    stop = [{"hooks": [{"type": "command", "command": TURN_COMMAND}]}]
    hooks = {"Stop": stop, "StopFailure": stop}
    if guard_slug:
        guard = os.path.join(HOME, "bin", "hooks", "guard-task-paths.sh")
        hooks["PreToolUse"] = [
            {
                "matcher": "Edit|Write|NotebookEdit|MultiEdit",
                "hooks": [{"type": "command", "command": f"CAP_HOME={shlex.quote(HOME)} {shlex.quote(guard)} {shlex.quote(guard_slug)}"}],
            }
        ]
    # The session records its own quota and context reading into this
    # Captain's state, whatever status line the user configured.
    statusline = f"CAP_HOME={shlex.quote(HOME)} {shlex.quote(os.path.join(HOME, 'bin', 'cap-statusline'))}"
    return json.dumps({"hooks": hooks, "statusLine": {"type": "command", "command": statusline}})


# codex runs a failed turn's end without its Stop hook, so a codex session
# also reports its start: the payload names the rollout, where a failed turn
# is recorded (codex_turn_error).
CODEX_HOOKS = (("SessionStart", "session_start", START_COMMAND), ("Stop", "stop", TURN_COMMAND))


def codex_hook_overrides():
    args = []
    for event, _, command in CODEX_HOOKS:
        # A JSON string is a valid TOML basic string, quotes in the command included.
        args += ["-c", "hooks.%s=[{hooks=[{type=\"command\",command=%s}]}]" % (event, json.dumps(command))]
    return args


def codex_hook_hash(label, command):
    """The hash codex stores when a user trusts one of the hooks above.

    codex hashes a canonical JSON form of the normalised hook
    (codex-rs/hooks/src/engine/discovery.rs, hook_hash). Captain seeds the
    same value so a launch never stops on the "Hooks need review" prompt.
    """
    identity = {
        "event_name": label,
        "hooks": [{"type": "command", "command": command, "async": False, "timeout": 600}],
    }
    body = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(body).hexdigest()


def codex_trust_hooks():
    cfg = os.path.expanduser("~/.codex/config.toml")
    if not os.path.isfile(cfg):
        return
    with open(cfg + ".cap-lock", "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        with open(cfg) as fh:
            text = original = fh.read()
        for _, label, command in CODEX_HOOKS:
            key = f'[hooks.state."/<session-flags>/config.toml:{label}:0:0"]'
            want = f'trusted_hash = "{codex_hook_hash(label, command)}"'
            if f"{key}\n{want}" in text:
                continue
            pattern = re.escape(key) + r"\ntrusted_hash = \"[^\"]*\""
            if re.search(pattern, text):
                text = re.sub(pattern, lambda _: f"{key}\n{want}", text)
            else:
                text = text.rstrip("\n") + f"\n\n{key}\n{want}\n"
        if text == original:
            return
        tmp = cfg + ".cap-tmp"
        with open(tmp, "w") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, cfg)


def trust(harness, directory):
    lib("harness_trust", harness, directory)
    if harness == "codex":
        codex_trust_hooks()


def session_argv(harness, model, effort, prompt, *, session_id=None, resume=None, guard_slug=None):
    """The one command line a Captain session starts with, for either harness."""
    if harness == "claude":
        argv = ["claude"]
        if model and model != "-":
            argv += ["--model", model]
        if effort:
            argv += ["--effort", effort]
        argv += ["--settings", claude_settings(guard_slug)]
        argv += shlex.split(conf("CAP_AGENT_FLAGS", "--permission-mode bypassPermissions"))
        if resume:
            argv += ["--resume", resume]
        elif session_id:
            argv += ["--session-id", session_id]
        return argv + [prompt]
    if harness == "codex":
        # codex's --output-schema exists only for exec, which is print mode.
        # Structured output travels in the answer and Captain validates it.
        argv = ["codex"]
        if resume:
            argv += ["resume", resume]
        if model and model != "-":
            argv += ["--model", model]
        if effort:
            argv += ["-c", f"model_reasoning_effort={effort}"]
        argv += codex_hook_overrides() + ["--dangerously-bypass-approvals-and-sandbox"]
        if guard_slug:
            warn(f"{guard_slug}: --owns is not enforced under codex; the guard is a claude hook")
        return argv + [prompt]
    raise CapError(f"unknown harness '{harness}'")


# --- herdr -----------------------------------------------------------------


def herdr(*args, check=True):
    proc = subprocess.run(["herdr", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        if check:
            raise CapError(f"herdr {args[0]} {args[1] if len(args) > 1 else ''} failed: {proc.stderr.strip()}")
        return None
    try:
        return json.loads(proc.stdout) if proc.stdout.strip() else {}
    except json.JSONDecodeError:
        return {"raw": proc.stdout}


def require_herdr():
    if not (os.environ.get("HERDR_ENV") and shutil.which("herdr")):
        raise CapError("herdr not detected: HERDR_ENV unset or herdr not on PATH")


def pane_exists(pane):
    return herdr("pane", "get", pane, check=False) is not None


def pane_status(pane):
    out = herdr("agent", "get", pane, check=False) or {}
    return ((out.get("result") or {}).get("agent") or {}).get("agent_status") or "unknown"


def pane_close(pane):
    herdr("pane", "close", pane, check=False)


def pane_tail(pane, lines=15):
    proc = subprocess.run(
        ["herdr", "pane", "read", pane, "--source", "visible", "--lines", str(lines)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return proc.stdout.strip()


def pane_type(pane, text):
    """Type text into a session's input box and submit it.

    herdr's send-text has no backpressure and a TUI drops a long burst, so
    the text goes in chunks.
    """
    for i in range(0, len(text), 400):
        herdr("pane", "send-text", pane, text[i : i + 400], check=False)
        time.sleep(0.15)
    time.sleep(0.4)
    herdr("pane", "send-keys", pane, "enter", check=False)


# --- sessions --------------------------------------------------------------


def live_path(session):
    return os.path.join(session.turn_dir, "live.json")


def publish_live(session, profile, directory):
    """Publish enough identity for another cap command to reach this pane."""
    record = {
        "directory": directory,
        "harness": profile.harness,
        "label": session.label,
        "pane": session.pane,
        "pid": os.getpid(),
        "profile": profile.name,
        "session_id": session.session_id,
        "started": session.started,
        "turn_dir": session.turn_dir,
    }
    path = live_path(session)
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w") as fh:
        json.dump(record, fh)
    os.replace(tmp, path)


def unpublish_live(session):
    try_remove(live_path(session))


def refresh_live(session, profile, directory):
    path = live_path(session)
    if os.path.exists(path):
        publish_live(session, profile, directory)


@dataclass
class Session:
    harness: str
    pane: str
    tab: str
    turn_dir: str
    label: str
    session_id: str = ""
    started: float = field(default_factory=time.time)
    seen: set = field(default_factory=set)
    codex_errors: int = 0


def launch(directory, label, argv, turn_dir, env=None):
    """Open a pane and start a session in it. Returns without waiting."""
    require_herdr()
    os.makedirs(turn_dir, exist_ok=True)
    opened = herdr("tab", "create", "--cwd", directory, "--label", label)
    root = (opened.get("result") or {}).get("root_pane") or {}
    pane = root.get("pane_id")
    if not pane:
        raise CapError("herdr tab create returned no pane id")
    tab = ((opened.get("result") or {}).get("tab") or {}).get("tab_id", "")
    try:
        extra = {"CAP_TURN_DIR": turn_dir, "CAP_SESSION_HOOK": EVENT_HOOK, **(env or {})}
        command = launch_env_prefix(extra) + argv
        script = os.path.join(turn_dir, f"launch-{int(time.time() * 1000)}.sh")
        exited = os.path.join(turn_dir, "exited")
        with open(script, "w") as fh:
            # Not exec: the exit marker is how a waiting dispatcher learns the
            # session is gone while its pane, and the shell in it, live on.
            fh.write("#!/usr/bin/env bash\n")
            fh.write(" ".join(shlex.quote(a) for a in command) + "\n")
            fh.write(f"printf '%s\\n' \"$?\" >{shlex.quote(exited)}\n")
        # Both belong to an earlier session in the same directory, and are
        # settled before the run, so neither can be read as this session's.
        try_remove(exited)
        seen = set(turn_files(turn_dir))
        herdr("pane", "run", pane, f"bash {shlex.quote(script)}")
    except BaseException:
        pane_close(pane)
        raise
    return Session(harness=argv[0], pane=pane, tab=tab, turn_dir=turn_dir, label=label, seen=seen)


_live_sessions = {}


def track(session):
    _live_sessions[session.pane] = session


def untrack(session):
    _live_sessions.pop(session.pane, None)


def close_live_sessions():
    for session in list(_live_sessions.values()):
        warn(f"{session.label}: stopped; closing pane {session.pane}")
        unpublish_live(session)
        pane_close(session.pane)
    _live_sessions.clear()


def turn_files(turn_dir):
    try:
        return sorted(f for f in os.listdir(turn_dir) if f.endswith(".json") and not f.startswith("."))
    except OSError:
        return []


class TurnLost(CapError):
    """The session ended, or its pane went away, before a turn finished."""


class TurnTimeout(CapError):
    pass


class TurnFailed(CapError):
    """The harness recorded the turn as failed without ending it through a hook."""


# How long a session herdr reports idle, with no turn file, counts as one
# that stopped without ending its turn. herdr reports a session working for
# the whole of a tool call and idle from the moment its turn ends, so this
# only has to outlast the gap between the two.
IDLE_GRACE = 20


def session_start(session):
    """The SessionStart payload the session wrote, or {} before it has."""
    try:
        with open(os.path.join(session.turn_dir, "session.start")) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def codex_turn_error(session):
    """The error of a codex turn that failed, read from its rollout.

    Counts every failed task_complete, so an error from a turn this
    dispatcher already handled is not reported twice.
    """
    rollout = session_start(session).get("transcript_path")
    if not rollout:
        return None
    errors = []
    for entry in read_jsonl(rollout or ""):
        payload = entry.get("payload") or {}
        if entry.get("type") == "event_msg" and payload.get("type") == "task_complete" and payload.get("error"):
            errors.append(payload["error"].get("message") or "unknown error")
    if len(errors) > session.codex_errors:
        session.codex_errors = len(errors)
        return errors[-1]
    return None


def wait_turn(session, max_wait=None):
    """Block until the session's next turn ends, and return its payload.

    Every way out is a signal something recorded: a turn file, the exit
    marker, a pane herdr no longer has, a failure codex wrote to its rollout,
    or herdr reporting the session idle for IDLE_GRACE seconds with none of
    those. Idle is herdr's reading of the harness, not pane output going
    quiet, which a long tool call also does.
    """
    max_wait = max_wait or int(conf("CAP_ASK_MAX_WAIT", "3600"))
    deadline = time.time() + max_wait
    warned_blocked = False
    idle_since = None
    polls = 0
    while True:
        # Read before the turn files: a session writes its last turn file
        # before it exits, so one that exited has no turn file still to come.
        exited = os.path.exists(os.path.join(session.turn_dir, "exited"))
        fresh = [f for f in turn_files(session.turn_dir) if f not in session.seen]
        if fresh:
            name = fresh[0]
            session.seen.add(name)
            with open(os.path.join(session.turn_dir, name)) as fh:
                payload = json.load(fh)
            session.session_id = payload.get("session_id") or session.session_id
            return payload
        polls += 1
        if session.harness == "codex" and (exited or polls % 3 == 0):
            error = codex_turn_error(session)
            if error:
                raise TurnFailed(f"{session.label}: codex turn failed: {error}")
        if exited:
            raise TurnLost(f"{session.label}: the {session.harness} session exited before its turn ended. Its pane showed:\n{pane_tail(session.pane)}")
        # herdr is asked every few seconds, not every poll: a turn file is
        # the signal, herdr only catches a pane that died or went quiet.
        if polls % 3 == 0:
            if not pane_exists(session.pane):
                raise TurnLost(f"{session.label}: pane {session.pane} no longer exists")
            status = pane_status(session.pane)
            if not warned_blocked and status == "blocked":
                warn(f"{session.label}: waiting on a prompt; answer it in pane {session.pane}")
                warned_blocked = True
            # herdr's done is idle that no client has looked at yet.
            if status not in ("idle", "done"):
                idle_since = None
            elif idle_since is None:
                idle_since = time.time()
            elif time.time() - idle_since >= IDLE_GRACE and not [f for f in turn_files(session.turn_dir) if f not in session.seen]:
                raise TurnLost(f"{session.label}: the {session.harness} session went idle without ending its turn. Its pane showed:\n{pane_tail(session.pane)}")
        if time.time() >= deadline:
            raise TurnTimeout(f"{session.label}: still running after {max_wait}s. Its pane showed:\n{pane_tail(session.pane)}")
        time.sleep(1)


def submit(session, text):
    pane_type(session.pane, text)


# --- reading a turn --------------------------------------------------------


def read_jsonl(path):
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def transcript_answer(harness, path):
    """The last assistant text of the latest turn, read from the transcript.

    The Stop payload's last_assistant_message is empty when a turn's final
    message is a tool call with no text.
    """
    texts = []
    for entry in read_jsonl(path or ""):
        if harness == "claude":
            msg = entry.get("message") or {}
            if entry.get("type") == "user" and is_prompt(msg.get("content")):
                texts = []
            if entry.get("type") == "assistant":
                for block in msg.get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "text" and block.get("text", "").strip():
                        texts.append(block["text"])
        else:
            payload = entry.get("payload") or {}
            if entry.get("type") != "response_item" or payload.get("type") != "message":
                continue
            if payload.get("role") == "user":
                texts = []
            if payload.get("role") == "assistant":
                for block in payload.get("content") or []:
                    if block.get("type") == "output_text" and block.get("text", "").strip():
                        texts.append(block["text"])
    return texts[-1] if texts else ""


def is_prompt(content):
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return False


def turn_answer(harness, payload):
    msg = payload.get("last_assistant_message") or ""
    if msg.strip():
        return msg
    return transcript_answer(harness, payload.get("transcript_path"))


class SessionLimit(CapError):
    """The account refused the turn."""


def classify(payload):
    """Raise for a turn that ended in a harness failure rather than an answer."""
    if payload.get("hook_event_name") != "StopFailure":
        return
    error = payload.get("error") or "unknown"
    details = payload.get("error_details") or payload.get("last_assistant_message") or ""
    if error == "rate_limit":
        raise SessionLimit(details)
    raise CapError(f"claude harness reported {error}{': ' + details if details else ''}")


# --- cost ------------------------------------------------------------------


def claude_tokens(transcript, since):
    """Exact tokens a claude session spent after `since`, summed per message.

    The transcript writes one line per content block and repeats the same
    message usage on each, so a message is counted once by its id.
    """
    seen = {}
    for entry in read_jsonl(transcript or ""):
        if entry.get("type") != "assistant":
            continue
        stamp = parse_iso(entry.get("timestamp"))
        if stamp is not None and stamp < since:
            continue
        msg = entry.get("message") or {}
        usage = msg.get("usage")
        if usage and msg.get("id"):
            seen[msg["id"]] = usage
    total = {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0}
    for u in seen.values():
        total["input"] += u.get("input_tokens") or 0
        total["output"] += u.get("output_tokens") or 0
        total["cache_creation"] += u.get("cache_creation_input_tokens") or 0
        total["cache_read"] += u.get("cache_read_input_tokens") or 0
    return total


def codex_last_count(transcript):
    """The last token_count event of a codex rollout: running totals and the account's windows."""
    last = None
    for entry in read_jsonl(transcript or ""):
        payload = entry.get("payload") or {}
        if entry.get("type") == "event_msg" and payload.get("type") == "token_count":
            last = payload
    return last


def codex_tokens(transcript):
    last = codex_last_count(transcript)
    usage = ((last or {}).get("info") or {}).get("total_token_usage") or {}
    return {
        "input": (usage.get("input_tokens") or 0) - (usage.get("cached_input_tokens") or 0),
        "output": usage.get("output_tokens") or 0,
        "cache_creation": usage.get("cache_write_input_tokens") or 0,
        "cache_read": usage.get("cached_input_tokens") or 0,
    }


def parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def session_reading(session_id):
    """The status-line record this session wrote for itself, if any."""
    try:
        with open(os.path.join(USAGE, f"{session_id}.json")) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def window_pct(harness, session_id, transcript, since):
    """The account's 5h window utilization as this session last saw it."""
    if harness == "claude":
        # The status line renders on its own schedule, so its first reading
        # can land a moment after the turn that prompted it.
        for _ in range(20):
            reading = session_reading(session_id)
            pct = (reading.get("five_hour") or {}).get("pct")
            if (reading.get("at") or 0) >= since and pct is not None:
                return pct
            time.sleep(0.5)
        return None
    last = codex_last_count(transcript)
    return (((last or {}).get("rate_limits") or {}).get("primary") or {}).get("used_percent")


def usage_now(harness):
    """The account's 5h utilization right before a dispatch, and where it came from."""
    if harness == "codex":
        try:
            limits = json.loads(lib("codex_rate_limits", check=False) or "{}")
        except json.JSONDecodeError:
            limits = {}
        return (limits.get("primary") or {}).get("used_percent"), limits.get("source") or "none"
    newest = {}
    try:
        names = [n for n in os.listdir(USAGE) if n.endswith(".json")]
    except OSError:
        names = []
    for name in names:
        try:
            with open(os.path.join(USAGE, name)) as fh:
                reading = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        if reading.get("harness", "claude") == "claude" and (reading.get("at") or 0) > (newest.get("at") or 0):
            newest = reading
    pct = (newest.get("five_hour") or {}).get("pct")
    if pct is None:
        return None, "none"
    return pct, f"status line, {now() - newest['at']}s old"


def record_cost(session, profile, window_start, transcript):
    """Append this dispatch's cost to the dispatch log.

    tokens is exact, read from the session's own transcript. window is the
    account's 5h utilization before and after: anything else running on the
    account during the turn is inside that difference, so it is labelled as
    account-wide and never as this dispatch's consumption.
    """
    if profile.harness == "claude":
        tokens = claude_tokens(transcript, session.started)
    else:
        tokens = codex_tokens(transcript)
    start_pct, start_src = window_start
    end_pct = window_pct(profile.harness, session.session_id, transcript, int(session.started))
    record = {
        "at": iso_now(),
        "caller": os.path.basename(sys.argv[0]),
        "kind": "cost",
        "label": session.label,
        "role": profile.role,
        "profile": profile.name,
        "harness": profile.harness,
        "session": session.session_id,
        "seconds": int(time.time() - session.started),
        "tokens": tokens,
        "window_5h_account_wide": {"start": start_pct, "start_source": start_src, "end": end_pct},
    }
    lib("dispatch_log_json", json.dumps(record), check=False)


# --- one question, one answer ----------------------------------------------


class InvalidAnswer(CapError):
    """The session kept answering without what the task asked for."""


@dataclass
class Answer:
    text: str
    session_id: str


def resume_key(profile, directory, prompt, label):
    """Names one call, so a rerun of it resumes it.

    The label is part of it, so two reviewers given the same prompt on the
    same profile never resume each other's session.
    """
    psha = hashlib.sha256(prompt.encode()).hexdigest()[:16]
    raw = "\x1f".join([profile.name, directory, psha, label, os.environ.get("CAP_ASK_KEY", "")])
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def resume_dir():
    d = os.path.join(HOME, "state", "ask-resume")
    os.makedirs(d, exist_ok=True)
    return d


def pending_resume(profile, key):
    """The session a session-limit rejection left for this exact call to resume.

    Resumes a record under 30% context. A fuller one starts fresh unless
    CAP_ASK_RESUME=force, because a resumed session that is already large
    compacts before it can finish.
    """
    if profile.harness != "claude":
        return None, None
    path = os.path.join(resume_dir(), f"{key}.json")
    try:
        with open(path) as fh:
            record = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None, None
    sid = record.get("session_id")
    ctx = record.get("ctx_pct")
    if not sid:
        return None, path
    if isinstance(ctx, int) and ctx < 30:
        return sid, path
    if os.environ.get("CAP_ASK_RESUME") == "force":
        return sid, path
    warn(f"pending session {sid} is at {ctx if ctx is not None else 'an unknown'}% context (>=30%); starting fresh instead of resuming. Set CAP_ASK_RESUME=force to resume it.")
    return None, path


CONTINUE = "Continue exactly where you left off in this conversation and finish the task. If you already reached a final conclusion before being interrupted, just restate it clearly now."


def ask(profile, prompt, directory, *, label=None, validate=None, repairs=2, guard_slug=None):
    """Run one question in a real session and return its validated answer.

    validate(text) returns a list of problems. Each problem list goes back
    into the same live session as a correction turn, so a malformed report
    is repaired by the agent that wrote it instead of re-reviewed from zero.
    """
    directory = os.path.realpath(directory)
    prune(os.path.join(HOME, "state", "ask"))
    prune(resume_dir())
    effort = effective_effort(profile)
    label = label or f"ask-{os.path.basename(directory)}-{profile.name}"
    key = resume_key(profile, directory, prompt, label)
    resume, record_path = pending_resume(profile, key)
    turn_dir = os.path.join(HOME, "state", "ask", uuid.uuid4().hex)

    trust(profile.harness, directory)
    sid = str(uuid.uuid4()) if profile.harness == "claude" and not resume else None
    argv = session_argv(
        profile.harness,
        profile.model,
        effort,
        CONTINUE if resume else prompt,
        session_id=sid,
        resume=resume,
        guard_slug=guard_slug,
    )
    window_start = usage_now(profile.harness)
    session = launch(directory, label, argv, turn_dir)
    track(session)
    session.session_id = sid or resume or ""
    transcript = ""
    try:
        publish_live(session, profile, directory)
        attempt = 0
        while True:
            payload = wait_turn(session)
            transcript = payload.get("transcript_path") or transcript
            refresh_live(session, profile, directory)
            classify(payload)
            text = turn_answer(profile.harness, payload)
            problems = validate(text) if validate else ([] if text.strip() else ["the answer was empty"])
            if not problems:
                if record_path:
                    try_remove(record_path)
                return Answer(text, session.session_id)
            if attempt >= repairs:
                raise InvalidAnswer(f"{label}: answer still invalid after {repairs} correction(s): " + "; ".join(problems))
            attempt += 1
            submit(session, correction(problems))
    except SessionLimit as e:
        limit_reached(profile, session, key, resume, record_path, str(e))
    except TurnFailed:
        if profile.harness == "codex":
            reached = lib("codex_limit_reached").strip()
            if reached:
                codex_limit(profile, reached)
        raise
    finally:
        # A turn that failed before any payload still ran: codex's
        # SessionStart names its rollout, which holds what it spent.
        start = session_start(session)
        session.session_id = session.session_id or start.get("session_id") or ""
        record_cost(session, profile, window_start, transcript or start.get("transcript_path") or "")
        unpublish_live(session)
        untrack(session)
        pane_close(session.pane)


def prune(directory, days=7):
    """Drop dispatch records nobody will read again. The harness keeps its own transcripts."""
    cutoff = time.time() - days * 86400
    try:
        names = os.listdir(directory)
    except OSError:
        return
    for name in names:
        path = os.path.join(directory, name)
        try:
            if os.path.getmtime(path) >= cutoff:
                continue
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                os.remove(path)
        except OSError:
            continue


def correction(problems):
    # One line: a newline typed into a TUI input box can submit half of it.
    return "Your last message is missing what this task asked for: " + "; ".join(problems) + ". Send your complete answer again, as the task describes, with these fixed."


def try_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def limit_reached(profile, session, key, resumed, record_path, details):
    reading = session_reading(session.session_id)
    ctx = reading.get("ctx_pct")
    resets = 0
    for window in ("five_hour", "seven_day"):
        w = reading.get(window) or {}
        if (w.get("pct") or 0) >= 100:
            resets = max(resets, w.get("resets_at") or 0)
    lib("profile_block", profile.name, str(resets))
    # A fresh run that was itself rejected must not overwrite a pending
    # record from the session it chose not to resume: CAP_ASK_RESUME=force
    # can still recover that one.
    target = os.path.join(resume_dir(), f"{key}.json")
    if resumed or not (record_path and os.path.exists(record_path)):
        with open(target, "w") as fh:
            json.dump({"profile": profile.name, "session_id": session.session_id, "ctx_pct": ctx if isinstance(ctx, int) else 100}, fh)
    until = lib("profile_block_until", profile.name).strip()
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(until or 0)))
    raise CapError(
        f"claude harness hit its session limit ({details or 'rate_limit'}); no result to return. "
        f"{profile.name} is out of its tier until {when}. Retrying this exact call later resumes session "
        f"{session.session_id} if it was under 30% context, or with CAP_ASK_RESUME=force."
    )


def codex_limit(profile, reached):
    resets = (lib("usage_read", "codex").split() + ["-", "0"])[1]
    lib("profile_block", profile.name, resets)
    until = lib("profile_block_until", profile.name).strip()
    when = time.strftime("%H:%M", time.localtime(int(until or 0)))
    raise CapError(f"codex harness reported a rate limit ({reached}); no result to return. {profile.name} is out of its tier until {when}.")


# --- structured findings ---------------------------------------------------

SEVERITIES = ("blocker", "major", "minor")
CONFIDENCE = ("confirmed", "suspected")
FAILING = ("blocker", "major")
FENCE = re.compile(r"```json[ \t]*\n(.*?)\n[ \t]*```", re.S)


def findings_block(text):
    """The last fenced json block in an answer, parsed, or an error string."""
    blocks = FENCE.findall(text or "")
    if not blocks:
        return None, "the answer has no ```json block"
    try:
        return json.loads(blocks[-1]), None
    except json.JSONDecodeError as e:
        return None, f"the ```json block does not parse: {e}"


def substantive(value):
    """A claim or note Captain can act on: three words or more.

    "ok", "fine" or "checked" say nothing about what was verified, and a
    report made only of those is a verdict with no review behind it.
    """
    return isinstance(value, str) and len(value.split()) >= 3


def validate_findings(report, changed, tree):
    """Problems with a findings report, as sentences the reviewer can act on.

    A report is accepted only when every changed file is accounted for, in
    a finding or in a note of what was checked. That is what separates a
    review from a bare verdict: nothing the reviewer says about coverage is
    taken on trust, it is compared with the diff.
    """
    if not isinstance(report, dict):
        return ["the json block must be an object with findings and checked"]
    problems = []
    findings = report.get("findings")
    checked = report.get("checked")
    if not isinstance(findings, list):
        problems.append("findings must be a list (empty when nothing is wrong)")
        findings = []
    if not isinstance(checked, list):
        problems.append("checked must be a list")
        checked = []
    covered = set()
    for i, f in enumerate(findings):
        where = f"findings[{i}]"
        if not isinstance(f, dict):
            problems.append(f"{where} must be an object")
            continue
        path = f.get("file")
        if not isinstance(path, str) or not known_path(path, changed, tree):
            problems.append(f"{where}.file {path!r} is not a file in this worktree")
        else:
            covered.add(path)
            line_problem = check_line(f.get("line"), path, tree)
            if line_problem:
                problems.append(f"{where}.line {line_problem}")
        if f.get("severity") not in SEVERITIES:
            problems.append(f"{where}.severity must be one of {', '.join(SEVERITIES)}")
        if f.get("confidence") not in CONFIDENCE:
            problems.append(f"{where}.confidence must be one of {', '.join(CONFIDENCE)}")
        if not substantive(f.get("claim")):
            problems.append(f"{where}.claim must say what is wrong and the failure it causes")
    for i, c in enumerate(checked):
        where = f"checked[{i}]"
        if not isinstance(c, dict):
            problems.append(f"{where} must be an object")
            continue
        path = c.get("file")
        if not isinstance(path, str) or not known_path(path, changed, tree):
            problems.append(f"{where}.file {path!r} is not a file in this worktree")
            continue
        if not substantive(c.get("note")):
            problems.append(f"{where}.note must say what you verified in {path}")
            continue
        covered.add(path)
    missing = [p for p in changed if p not in covered]
    if missing:
        problems.append("these changed files are in neither findings nor checked: " + ", ".join(missing))
    return problems


def known_path(path, changed, tree):
    if path in changed:
        return True
    if path.startswith("/") or ".." in path.split("/"):
        return False
    return os.path.isfile(os.path.join(tree, path))


def check_line(line, path, tree):
    if line is None:
        return None
    if not isinstance(line, int) or isinstance(line, bool) or line < 1:
        return "must be a positive integer or null"
    full = os.path.join(tree, path)
    if not os.path.isfile(full):
        return None
    with open(full, "rb") as fh:
        count = sum(1 for _ in fh)
    if line > count:
        return f"{line} is past the end of {path} ({count} lines)"
    return None


def verdict(report):
    failing = [
        f
        for f in report.get("findings", [])
        if f.get("severity") in FAILING and f.get("confidence") == "confirmed"
    ]
    return "FAIL" if failing else "PASS"


def finding_id(f):
    """A handle for one finding that survives a line number moving."""
    raw = f"{f.get('file')}\x1f{' '.join(str(f.get('claim', '')).split()).lower()}"
    return hashlib.sha256(raw.encode()).hexdigest()[:8]
