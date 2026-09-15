"""Harness sessions, turns, transcripts, and usage tracking for Captain.

Captain reads completed turns from harness payloads, not pane output.
Git, worktree, and task state stay in bin/lib.sh.
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

# Codex trusts hooks by command hash. Keep these commands independent of
# the Captain checkout and task so the same trust applies to every launch.
TURN_COMMAND = '"${CAP_SESSION_HOOK:-true}" turn'
START_COMMAND = '"${CAP_SESSION_HOOK:-true}" start'


class CapError(Exception):
    """A failure reported as `cap: <message>` with exit status 1."""


class LibFailed(CapError):
    """A lib.sh function already reported its failure on stderr."""


def warn(msg):
    print(f"cap: {msg}", file=sys.stderr, flush=True)


def run_main(main):
    # Closing the dispatcher must also stop sessions nobody will collect.
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

        # A waiting reviewer thread can keep the process alive after its pane closes.
        os._exit(130)


def _interrupted(signum, frame):
    raise KeyboardInterrupt


def lib(func, *args, check=True):
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
    env = dict(os.environ, CAP_HOME=HOME)
    proc = subprocess.run(
        ["bash", "-c", '. "$0"; printf "%s" "${!1:-}"', LIB, name],
        stdout=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        text=True,
        env=env,
    )

    if proc.stdout:
        return proc.stdout

    return default


def now():
    return int(time.time())


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Profile:
    name: str
    harness: str
    model: str
    effort: str
    role: str = ""


def resolve_profile(spec):
    role = ""
    name = spec

    if spec.startswith("@"):
        role = spec[1:]
        name = lib("role_profile_or_die", role).strip()

    harness, model, effort = lib("ask_profile", name).split()
    return Profile(name, harness, model, effort, role)


def effective_effort(profile):
    if profile.effort != "-":
        return profile.effort

    if not profile.role:
        return ""

    return lib("role_effort", profile.role).strip()


def check_profile(profile):
    env = dict(os.environ, CAP_HOME=HOME)
    proc = subprocess.run(
        [
            "bash",
            "-c",
            '. "$0"; profile_check "$1" "$2"',
            LIB,
            profile.name,
            effective_effort(profile),
        ],
        stdout=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        text=True,
        env=env,
    )

    if proc.returncode != 0:
        raise CapError(
            f"profile '{profile.name}': {proc.stdout.strip()} (run cap models)"
        )

    if not shutil.which(profile.harness):
        raise CapError(f"{profile.harness} is not installed")


def task_field(slug, key):
    path = os.path.join(TASKS, slug, "task.env")

    try:
        with open(path) as fh:
            for line in fh:
                name, _, value = line.rstrip("\n").partition("=")
                if name == key:
                    return value
    except OSError:
        return None

    return None


def task_for_tree(directory):
    directory = os.path.realpath(directory)

    try:
        slugs = sorted(os.listdir(TASKS))
    except OSError:
        return None

    for slug in slugs:
        tree = task_field(slug, "CAP_TREE")
        if tree and os.path.realpath(tree) == directory:
            return slug

    return None


_held_locks = {}


def task_lock(slug):
    # CAP_LOCKS lets a command holding this task lock call another cap command.
    held = os.environ.get("CAP_LOCKS", "").split()
    if slug in held or slug in _held_locks:
        return

    directory = os.path.join(TASKS, slug)
    os.makedirs(directory, exist_ok=True)

    lock = open(os.path.join(directory, ".lock"), "a+")

    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.seek(0)
        holder = lock.read().strip() or "another cap command"
        lock.close()
        raise CapError(f"{slug} is already held by {holder}")

    lock.seek(0)
    lock.truncate()

    started = time.strftime("%H:%M:%SZ", time.gmtime())
    command = os.path.basename(sys.argv[0])
    lock.write(f"pid {os.getpid()} ({command}) since {started}\n")
    lock.flush()

    _held_locks[slug] = lock
    os.environ["CAP_LOCKS"] = " ".join(held + [slug])


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
    # Agents inherit only the CAP_* values set for this launch.
    unset = list(SCRUBBED)
    unset += sorted(name for name in os.environ if name.startswith("CAP_"))

    argv = ["env"]

    for name in unset:
        argv += ["-u", name]

    env = {**cache_env(), **extra}
    for name, value in env.items():
        argv.append(f"{name}={value}")

    return argv


def claude_settings(guard_slug):
    stop = [{"hooks": [{"type": "command", "command": TURN_COMMAND}]}]
    hooks = {
        "Stop": stop,
        "StopFailure": stop,
    }

    # Keep the guard outside the worktree so project changes cannot disable it.
    if guard_slug:
        guard = os.path.join(HOME, "bin", "hooks", "guard-task-paths.sh")
        command = (
            f"CAP_HOME={shlex.quote(HOME)} "
            f"{shlex.quote(guard)} "
            f"{shlex.quote(guard_slug)}"
        )
        hooks["PreToolUse"] = [
            {
                "matcher": "Edit|Write|NotebookEdit|MultiEdit",
                "hooks": [
                    {
                        "type": "command",
                        "command": command,
                    }
                ],
            }
        ]

    # The status line writes usage into this Captain checkout, regardless of
    # the user's normal status-line configuration.
    statusline = (
        f"CAP_HOME={shlex.quote(HOME)} "
        f"{shlex.quote(os.path.join(HOME, 'bin', 'cap-statusline'))}"
    )

    return json.dumps(
        {
            "hooks": hooks,
            "statusLine": {
                "type": "command",
                "command": statusline,
            },
        }
    )


# Codex can end a failed turn without running Stop. SessionStart gives us the
# rollout path, where that failure is recorded.
CODEX_HOOKS = (
    ("SessionStart", "session_start", START_COMMAND),
    ("Stop", "stop", TURN_COMMAND),
)


def codex_hook_overrides():
    args = []

    for event, _, command in CODEX_HOOKS:
        # JSON strings are valid TOML basic strings, including command quotes.
        args += [
            "-c",
            'hooks.%s=[{hooks=[{type="command",command=%s}]}]'
            % (event, json.dumps(command)),
        ]

    return args


def codex_hook_hash(label, command):
    # This must match Codex's canonical hook hash.
    identity = {
        "event_name": label,
        "hooks": [
            {
                "type": "command",
                "command": command,
                "async": False,
                "timeout": 600,
            }
        ],
    }
    body = json.dumps(
        identity,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()

    return "sha256:" + hashlib.sha256(body).hexdigest()


def codex_trust_hooks():
    config = os.path.expanduser("~/.codex/config.toml")
    if not os.path.isfile(config):
        return

    with open(config + ".cap-lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)

        with open(config) as fh:
            text = fh.read()

        original = text

        for _, label, command in CODEX_HOOKS:
            key = f'[hooks.state."/<session-flags>/config.toml:{label}:0:0"]'
            trusted_hash = f'trusted_hash = "{codex_hook_hash(label, command)}"'

            if f"{key}\n{trusted_hash}" in text:
                continue

            pattern = re.escape(key) + r'\ntrusted_hash = "[^"]*"'

            if re.search(pattern, text):
                text = re.sub(
                    pattern,
                    lambda _: f"{key}\n{trusted_hash}",
                    text,
                )
            else:
                text = text.rstrip("\n") + f"\n\n{key}\n{trusted_hash}\n"

        if text == original:
            return

        tmp = config + ".cap-tmp"
        with open(tmp, "w") as fh:
            fh.write(text)

        os.chmod(tmp, 0o600)
        os.replace(tmp, config)


def trust(harness, directory):
    lib("harness_trust", harness, directory)

    if harness == "codex":
        codex_trust_hooks()


def claude_session_argv(
    model,
    effort,
    prompt,
    *,
    session_id=None,
    resume=None,
    guard_slug=None,
):
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

    if prompt:
        argv.append(prompt)

    return argv


def codex_session_argv(model, effort, prompt, *, resume=None, guard_slug=None):
    argv = ["codex"]

    if resume:
        argv += ["resume", resume]

    if model and model != "-":
        argv += ["--model", model]

    if effort:
        argv += ["-c", f"model_reasoning_effort={effort}"]

    argv += codex_hook_overrides()
    argv += ["--dangerously-bypass-approvals-and-sandbox"]

    if guard_slug:
        warn(
            f"{guard_slug}: --owns is not enforced under codex; "
            "the guard is a claude hook"
        )

    if prompt:
        argv.append(prompt)

    return argv


def session_argv(
    harness,
    model,
    effort,
    prompt,
    *,
    session_id=None,
    resume=None,
    guard_slug=None,
):
    if harness == "claude":
        return claude_session_argv(
            model,
            effort,
            prompt,
            session_id=session_id,
            resume=resume,
            guard_slug=guard_slug,
        )

    if harness == "codex":
        return codex_session_argv(
            model,
            effort,
            prompt,
            resume=resume,
            guard_slug=guard_slug,
        )

    raise CapError(f"unknown harness '{harness}'")


def herdr(*args, check=True):
    proc = subprocess.run(
        ["herdr", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    if proc.returncode != 0:
        if check:
            command = " ".join(args[:2])
            raise CapError(f"herdr {command} failed: {proc.stderr.strip()}")

        return None

    if not proc.stdout.strip():
        return {}

    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"raw": proc.stdout}


def require_herdr():
    if not os.environ.get("HERDR_ENV") or not shutil.which("herdr"):
        raise CapError("herdr not detected: HERDR_ENV unset or herdr not on PATH")


def pane_exists(pane):
    return herdr("pane", "get", pane, check=False) is not None


def pane_status(pane):
    result = herdr("agent", "get", pane, check=False) or {}
    agent = (result.get("result") or {}).get("agent") or {}
    return agent.get("agent_status") or "unknown"


def pane_close(pane):
    herdr("pane", "close", pane, check=False)


def pane_tail(pane, lines=15):
    proc = subprocess.run(
        [
            "herdr",
            "pane",
            "read",
            pane,
            "--source",
            "visible",
            "--lines",
            str(lines),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return proc.stdout.strip()


def pane_type(pane, text):
    # A TUI can drop a long send-text burst, so send the input in chunks.
    for start in range(0, len(text), 400):
        chunk = text[start : start + 400]
        herdr("pane", "send-text", pane, chunk, check=False)
        time.sleep(0.15)

    time.sleep(0.4)
    herdr("pane", "send-keys", pane, "enter", check=False)


def live_path(session):
    return os.path.join(session.turn_dir, "live.json")


def publish_live(session, profile, directory):
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
    require_herdr()
    os.makedirs(turn_dir, exist_ok=True)

    opened = herdr("tab", "create", "--cwd", directory, "--label", label)
    result = opened.get("result") or {}
    root_pane = result.get("root_pane") or {}

    pane = root_pane.get("pane_id")
    if not pane:
        raise CapError("herdr tab create returned no pane id")

    tab = (result.get("tab") or {}).get("tab_id", "")

    try:
        extra = {
            "CAP_TURN_DIR": turn_dir,
            "CAP_SESSION_HOOK": EVENT_HOOK,
            **(env or {}),
        }
        command = launch_env_prefix(extra) + argv

        timestamp = int(time.time() * 1000)
        script = os.path.join(turn_dir, f"launch-{timestamp}.sh")
        exited = os.path.join(turn_dir, "exited")

        with open(script, "w") as fh:
            fh.write("#!/usr/bin/env bash\n")
            fh.write(" ".join(shlex.quote(arg) for arg in command) + "\n")

            # Keep the shell alive, but leave a marker when the harness exits.
            fh.write(f"printf '%s\\n' \"$?\" >{shlex.quote(exited)}\n")

        # These may belong to an earlier session using the same turn directory.
        try_remove(exited)
        seen = set(turn_files(turn_dir))

        herdr("pane", "run", pane, f"bash {shlex.quote(script)}")
    except BaseException:
        pane_close(pane)
        raise

    return Session(
        harness=argv[0],
        pane=pane,
        tab=tab,
        turn_dir=turn_dir,
        label=label,
        seen=seen,
    )


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
        return sorted(
            name
            for name in os.listdir(turn_dir)
            if name.endswith(".json") and not name.startswith(".")
        )
    except OSError:
        return []


class TurnLost(CapError):
    """The session disappeared before its turn finished."""


class TurnTimeout(CapError):
    pass


class TurnFailed(CapError):
    """The harness recorded a failed turn without ending it through a hook."""


# Herdr becomes idle when a turn ends. Allow the Stop hook time to write its
# payload before treating an idle session as a lost turn.
IDLE_GRACE = 20


def session_start(session):
    try:
        with open(os.path.join(session.turn_dir, "session.start")) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def codex_turn_error(session):
    rollout = session_start(session).get("transcript_path")
    if not rollout:
        return None

    errors = []

    for entry in read_jsonl(rollout):
        payload = entry.get("payload") or {}

        if (
            entry.get("type") == "event_msg"
            and payload.get("type") == "task_complete"
            and payload.get("error")
        ):
            error = payload["error"]
            errors.append(error.get("message") or "unknown error")

    if len(errors) <= session.codex_errors:
        return None

    session.codex_errors = len(errors)
    return errors[-1]


def fresh_turn(session):
    fresh = [name for name in turn_files(session.turn_dir) if name not in session.seen]

    if not fresh:
        return None

    name = fresh[0]
    session.seen.add(name)

    with open(os.path.join(session.turn_dir, name)) as fh:
        payload = json.load(fh)

    session.session_id = payload.get("session_id") or session.session_id
    return payload


def has_fresh_turn(session):
    return any(name not in session.seen for name in turn_files(session.turn_dir))


def check_pane_progress(session, warned_blocked, idle_since):
    if not pane_exists(session.pane):
        raise TurnLost(f"{session.label}: pane {session.pane} no longer exists")

    status = pane_status(session.pane)

    if not warned_blocked and status == "blocked":
        warn(f"{session.label}: waiting on a prompt; answer it in pane {session.pane}")
        warned_blocked = True

    if status not in ("idle", "done"):
        return warned_blocked, None

    if idle_since is None:
        return warned_blocked, time.time()

    idle_for = time.time() - idle_since
    if idle_for >= IDLE_GRACE and not has_fresh_turn(session):
        raise TurnLost(
            f"{session.label}: the {session.harness} session went idle "
            f"without ending its turn. Its pane showed:\n"
            f"{pane_tail(session.pane)}"
        )

    return warned_blocked, idle_since


def wait_turn(session, max_wait=None):
    max_wait = max_wait or int(conf("CAP_ASK_MAX_WAIT", "3600"))
    deadline = time.time() + max_wait

    warned_blocked = False
    idle_since = None
    polls = 0

    while True:
        # A harness writes its final turn before the exit marker. Check both
        # before deciding that an exited session lost its turn.
        exited = os.path.exists(os.path.join(session.turn_dir, "exited"))
        payload = fresh_turn(session)

        if payload is not None:
            return payload

        polls += 1

        if session.harness == "codex" and (exited or polls % 3 == 0):
            error = codex_turn_error(session)
            if error:
                raise TurnFailed(f"{session.label}: codex turn failed: {error}")

        if exited:
            raise TurnLost(
                f"{session.label}: the {session.harness} session exited "
                f"before its turn ended. Its pane showed:\n"
                f"{pane_tail(session.pane)}"
            )

        if polls % 3 == 0:
            warned_blocked, idle_since = check_pane_progress(
                session,
                warned_blocked,
                idle_since,
            )

        if time.time() >= deadline:
            raise TurnTimeout(
                f"{session.label}: still running after {max_wait}s. "
                f"Its pane showed:\n{pane_tail(session.pane)}"
            )

        time.sleep(1)


def submit_codex(session, text):
    if not session.session_id:
        return False

    proc = subprocess.run(
        [
            "codex",
            "queue",
            "--thread",
            session.session_id,
            "--message",
            text,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    if proc.returncode == 0:
        return True

    warn(
        f"{session.label}: codex queue failed ({proc.stderr.strip()}), "
        "falling back to pane_type"
    )
    return False


def submit(session, text):
    if session.harness == "codex" and submit_codex(session, text):
        return

    pane_type(session.pane, text)


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


def claude_transcript_answer(path):
    texts = []

    for entry in read_jsonl(path or ""):
        message = entry.get("message") or {}

        if entry.get("type") == "user" and is_prompt(message.get("content")):
            texts = []

        if entry.get("type") != "assistant":
            continue

        for block in message.get("content") or []:
            if not isinstance(block, dict):
                continue

            if block.get("type") != "text":
                continue

            text = block.get("text", "")
            if text.strip():
                texts.append(text)

    return texts[-1] if texts else ""


def codex_transcript_answer(path):
    texts = []

    for entry in read_jsonl(path or ""):
        payload = entry.get("payload") or {}

        if entry.get("type") != "response_item":
            continue

        if payload.get("type") != "message":
            continue

        if payload.get("role") == "user":
            texts = []

        if payload.get("role") != "assistant":
            continue

        for block in payload.get("content") or []:
            if block.get("type") != "output_text":
                continue

            text = block.get("text", "")
            if text.strip():
                texts.append(text)

    return texts[-1] if texts else ""


def transcript_answer(harness, path):
    if harness == "claude":
        return claude_transcript_answer(path)

    return codex_transcript_answer(path)


def is_prompt(content):
    if isinstance(content, str):
        return True

    if not isinstance(content, list):
        return False

    return not any(
        isinstance(block, dict) and block.get("type") == "tool_result"
        for block in content
    )


def turn_answer(harness, payload):
    message = payload.get("last_assistant_message") or ""

    if message.strip():
        return message

    return transcript_answer(
        harness,
        payload.get("transcript_path"),
    )


class SessionLimit(CapError):
    """The account refused the turn."""


def classify(payload):
    if payload.get("hook_event_name") != "StopFailure":
        return

    error = payload.get("error") or "unknown"
    details = (
        payload.get("error_details") or payload.get("last_assistant_message") or ""
    )

    if error == "rate_limit":
        raise SessionLimit(details)

    suffix = f": {details}" if details else ""
    raise CapError(f"claude harness reported {error}{suffix}")


def claude_tokens(transcript, since):
    # Claude repeats message usage for each content block. Count each message ID once.
    seen = {}

    for entry in read_jsonl(transcript or ""):
        if entry.get("type") != "assistant":
            continue

        stamp = parse_iso(entry.get("timestamp"))
        if stamp is not None and stamp < since:
            continue

        message = entry.get("message") or {}
        usage = message.get("usage")
        message_id = message.get("id")

        if usage and message_id:
            seen[message_id] = usage

    total = {
        "input": 0,
        "output": 0,
        "cache_creation": 0,
        "cache_read": 0,
    }

    for usage in seen.values():
        total["input"] += usage.get("input_tokens") or 0
        total["output"] += usage.get("output_tokens") or 0
        total["cache_creation"] += usage.get("cache_creation_input_tokens") or 0
        total["cache_read"] += usage.get("cache_read_input_tokens") or 0

    return total


def codex_last_count(transcript):
    last = None

    for entry in read_jsonl(transcript or ""):
        payload = entry.get("payload") or {}

        if entry.get("type") == "event_msg" and payload.get("type") == "token_count":
            last = payload

    return last


def codex_tokens(transcript):
    last = codex_last_count(transcript)
    info = (last or {}).get("info") or {}
    usage = info.get("total_token_usage") or {}

    cached_input = usage.get("cached_input_tokens") or 0

    return {
        "input": (usage.get("input_tokens") or 0) - cached_input,
        "output": usage.get("output_tokens") or 0,
        "cache_creation": usage.get("cache_write_input_tokens") or 0,
        "cache_read": cached_input,
    }


def parse_iso(value):
    if not value:
        return None

    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def session_reading(session_id):
    try:
        with open(os.path.join(USAGE, f"{session_id}.json")) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def window_pct(harness, session_id, transcript, since):
    if harness == "claude":
        # The status line can update just after the turn finishes.
        for _ in range(20):
            reading = session_reading(session_id)
            pct = (reading.get("five_hour") or {}).get("pct")

            if (reading.get("at") or 0) >= since and pct is not None:
                return pct

            time.sleep(0.5)

        return None

    last = codex_last_count(transcript)
    rate_limits = (last or {}).get("rate_limits") or {}
    primary = rate_limits.get("primary") or {}
    return primary.get("used_percent")


def codex_usage_now():
    try:
        limits = json.loads(lib("codex_rate_limits", check=False) or "{}")
    except json.JSONDecodeError:
        limits = {}

    pct = (limits.get("primary") or {}).get("used_percent")
    source = limits.get("source") or "none"

    return pct, source


def claude_usage_now():
    newest = {}

    try:
        names = [name for name in os.listdir(USAGE) if name.endswith(".json")]
    except OSError:
        names = []

    for name in names:
        try:
            with open(os.path.join(USAGE, name)) as fh:
                reading = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue

        if reading.get("harness", "claude") != "claude":
            continue

        if (reading.get("at") or 0) > (newest.get("at") or 0):
            newest = reading

    pct = (newest.get("five_hour") or {}).get("pct")
    if pct is None:
        return None, "none"

    age = now() - newest["at"]
    return pct, f"status line, {age}s old"


def usage_now(harness):
    if harness == "codex":
        return codex_usage_now()

    return claude_usage_now()


def record_cost(session, profile, window_start, transcript):
    if profile.harness == "claude":
        tokens = claude_tokens(transcript, session.started)
    else:
        tokens = codex_tokens(transcript)

    start_pct, start_source = window_start
    end_pct = window_pct(
        profile.harness,
        session.session_id,
        transcript,
        int(session.started),
    )

    # Window utilization is account-wide and can include other concurrent sessions.
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
        "window_5h_account_wide": {
            "start": start_pct,
            "start_source": start_source,
            "end": end_pct,
        },
    }

    lib("dispatch_log_json", json.dumps(record), check=False)


class InvalidAnswer(CapError):
    """The session exhausted its answer correction attempts."""


@dataclass
class Answer:
    text: str
    session_id: str


def resume_key(profile, directory, prompt, label):
    # Include the label so identical reviewers do not resume each other's sessions.
    prompt_hash = hashlib.sha256(prompt.encode()).hexdigest()[:16]
    raw = "\x1f".join(
        [
            profile.name,
            directory,
            prompt_hash,
            label,
            os.environ.get("CAP_ASK_KEY", ""),
        ]
    )

    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def resume_dir():
    directory = os.path.join(HOME, "state", "ask-resume")
    os.makedirs(directory, exist_ok=True)
    return directory


def pending_resume(profile, key):
    if profile.harness != "claude":
        return None, None

    path = os.path.join(resume_dir(), f"{key}.json")

    try:
        with open(path) as fh:
            record = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None, None

    session_id = record.get("session_id")
    context_pct = record.get("ctx_pct")

    if not session_id:
        return None, path

    # Large resumed sessions may compact before they can finish the retry.
    if isinstance(context_pct, int) and context_pct < 30:
        return session_id, path

    if os.environ.get("CAP_ASK_RESUME") == "force":
        return session_id, path

    context = context_pct if context_pct is not None else "an unknown"
    warn(
        f"pending session {session_id} is at {context}% context (>=30%); "
        "starting fresh instead of resuming. "
        "Set CAP_ASK_RESUME=force to resume it."
    )

    return None, path


CONTINUE = (
    "Continue exactly where you left off in this conversation and finish the task. "
    "If you already reached a final conclusion before being interrupted, "
    "just restate it clearly now."
)


def prepare_ask(profile, prompt, directory, label, guard_slug):
    directory = os.path.realpath(directory)

    prune(os.path.join(HOME, "state", "ask"))
    prune(resume_dir())

    effort = effective_effort(profile)
    key = resume_key(profile, directory, prompt, label)
    resume, record_path = pending_resume(profile, key)
    turn_dir = os.path.join(
        HOME,
        "state",
        "ask",
        uuid.uuid4().hex,
    )

    trust(profile.harness, directory)

    session_id = None
    if profile.harness == "claude" and not resume:
        session_id = str(uuid.uuid4())

    argv = session_argv(
        profile.harness,
        profile.model,
        effort,
        CONTINUE if resume else prompt,
        session_id=session_id,
        resume=resume,
        guard_slug=guard_slug,
    )

    window_start = usage_now(profile.harness)
    session = launch(directory, label, argv, turn_dir)

    track(session)
    session.session_id = session_id or resume or ""

    return {
        "key": key,
        "record_path": record_path,
        "resume": resume,
        "window_start": window_start,
        "session": session,
    }


def run_ask_turns(
    session,
    profile,
    directory,
    validate,
    repairs,
    record_path,
    label,
):
    transcript = ""
    attempt = 0

    while True:
        payload = wait_turn(session)
        transcript = payload.get("transcript_path") or transcript

        refresh_live(session, profile, directory)
        classify(payload)

        text = turn_answer(profile.harness, payload)

        if validate:
            problems = validate(text)
        elif text.strip():
            problems = []
        else:
            problems = ["the answer was empty"]

        if not problems:
            if record_path:
                try_remove(record_path)

            return Answer(text, session.session_id), transcript

        if attempt >= repairs:
            details = "; ".join(problems)
            raise InvalidAnswer(
                f"{label}: answer still invalid after "
                f"{repairs} correction(s): {details}"
            )

        attempt += 1
        submit(session, correction(problems))


def finish_ask(session, profile, window_start, transcript):
    start = session_start(session)
    session.session_id = session.session_id or start.get("session_id") or ""

    transcript = transcript or start.get("transcript_path") or ""
    record_cost(
        session,
        profile,
        window_start,
        transcript,
    )

    unpublish_live(session)
    untrack(session)
    pane_close(session.pane)


def ask(
    profile,
    prompt,
    directory,
    *,
    label=None,
    validate=None,
    repairs=2,
    guard_slug=None,
):
    directory = os.path.realpath(directory)
    label = label or (f"ask-{os.path.basename(directory)}-{profile.name}")

    context = prepare_ask(
        profile,
        prompt,
        directory,
        label,
        guard_slug,
    )
    session = context["session"]
    transcript = ""

    try:
        publish_live(session, profile, directory)

        answer, transcript = run_ask_turns(
            session,
            profile,
            directory,
            validate,
            repairs,
            context["record_path"],
            label,
        )
        return answer
    except SessionLimit as e:
        limit_reached(
            profile,
            session,
            context["key"],
            context["resume"],
            context["record_path"],
            str(e),
        )
    except TurnFailed:
        if profile.harness == "codex":
            reached = lib("codex_limit_reached").strip()
            if reached:
                codex_limit(profile, reached)

        raise
    finally:
        finish_ask(
            session,
            profile,
            context["window_start"],
            transcript,
        )


def prune(directory, days=7):
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
    # Newlines can submit a partial message in the TUI.
    return (
        "Your last message is missing what this task asked for: "
        + "; ".join(problems)
        + ". Send your complete answer again, as the task describes, "
        "with these fixed."
    )


def try_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def limit_reached(
    profile,
    session,
    key,
    resumed,
    record_path,
    details,
):
    reading = session_reading(session.session_id)
    context_pct = reading.get("ctx_pct")

    resets = 0
    for window in ("five_hour", "seven_day"):
        usage = reading.get(window) or {}

        if (usage.get("pct") or 0) >= 100:
            resets = max(
                resets,
                usage.get("resets_at") or 0,
            )

    lib("profile_block", profile.name, str(resets))

    target = os.path.join(resume_dir(), f"{key}.json")

    # Do not replace an older resumable session when a fresh retry is rejected.
    if resumed or not (record_path and os.path.exists(record_path)):
        with open(target, "w") as fh:
            json.dump(
                {
                    "profile": profile.name,
                    "session_id": session.session_id,
                    "ctx_pct": (context_pct if isinstance(context_pct, int) else 100),
                },
                fh,
            )

    until = lib("profile_block_until", profile.name).strip()
    when = time.strftime(
        "%Y-%m-%d %H:%M",
        time.localtime(int(until or 0)),
    )

    raise CapError(
        f"claude harness hit its session limit "
        f"({details or 'rate_limit'}); no result to return. "
        f"{profile.name} is out of its tier until {when}. "
        f"Retrying this exact call later resumes session "
        f"{session.session_id} if it was under 30% context, "
        "or with CAP_ASK_RESUME=force."
    )


def codex_limit(profile, reached):
    usage = lib("usage_read", "codex").split()
    resets = (usage + ["-", "0"])[1]

    lib("profile_block", profile.name, resets)

    until = lib("profile_block_until", profile.name).strip()
    when = time.strftime(
        "%H:%M",
        time.localtime(int(until or 0)),
    )

    raise CapError(
        f"codex harness reported a rate limit ({reached}); "
        f"no result to return. "
        f"{profile.name} is out of its tier until {when}."
    )


SEVERITIES = ("blocker", "major", "minor")
CONFIDENCE = ("confirmed", "suspected")
FAILING = ("blocker", "major")
FENCE = re.compile(r"```json[ \t]*\n(.*?)\n[ \t]*```", re.S)


def findings_block(text):
    blocks = FENCE.findall(text or "")

    if not blocks:
        return None, "the answer has no ```json block"

    try:
        return json.loads(blocks[-1]), None
    except json.JSONDecodeError as e:
        return None, f"the ```json block does not parse: {e}"


def substantive(value):
    # Short verdicts such as "ok" or "checked" do not say what was verified.
    return isinstance(value, str) and len(value.split()) >= 3


def validate_finding(index, finding, changed, tree, covered):
    where = f"findings[{index}]"

    if not isinstance(finding, dict):
        return [f"{where} must be an object"]

    problems = []
    path = finding.get("file")

    if not isinstance(path, str) or not known_path(path, changed, tree):
        problems.append(f"{where}.file {path!r} is not a file in this worktree")
    else:
        covered.add(path)

        line_problem = check_line(
            finding.get("line"),
            path,
            tree,
        )
        if line_problem:
            problems.append(f"{where}.line {line_problem}")

    if finding.get("severity") not in SEVERITIES:
        problems.append(f"{where}.severity must be one of {', '.join(SEVERITIES)}")

    if finding.get("confidence") not in CONFIDENCE:
        problems.append(f"{where}.confidence must be one of {', '.join(CONFIDENCE)}")

    if not substantive(finding.get("claim")):
        problems.append(
            f"{where}.claim must say what is wrong and the failure it causes"
        )

    return problems


def validate_checked(index, checked, changed, tree, covered):
    where = f"checked[{index}]"

    if not isinstance(checked, dict):
        return [f"{where} must be an object"]

    path = checked.get("file")

    if not isinstance(path, str) or not known_path(path, changed, tree):
        return [f"{where}.file {path!r} is not a file in this worktree"]

    if not substantive(checked.get("note")):
        return [f"{where}.note must say what you verified in {path}"]

    covered.add(path)
    return []


def validate_findings(report, changed, tree):
    if not isinstance(report, dict):
        return ["the json block must be an object with findings and checked"]

    problems = []

    findings = report.get("findings")
    if not isinstance(findings, list):
        problems.append("findings must be a list (empty when nothing is wrong)")
        findings = []

    checked = report.get("checked")
    if not isinstance(checked, list):
        problems.append("checked must be a list")
        checked = []

    covered = set()

    for index, finding in enumerate(findings):
        problems.extend(
            validate_finding(
                index,
                finding,
                changed,
                tree,
                covered,
            )
        )

    for index, item in enumerate(checked):
        problems.extend(
            validate_checked(
                index,
                item,
                changed,
                tree,
                covered,
            )
        )

    missing = [path for path in changed if path not in covered]

    if missing:
        problems.append(
            "these changed files are in neither findings nor checked: "
            + ", ".join(missing)
        )

    return problems


def known_path(path, changed, tree):
    if path in changed:
        return True

    if path.startswith("/"):
        return False

    if ".." in path.split("/"):
        return False

    return os.path.isfile(os.path.join(tree, path))


def check_line(line, path, tree):
    if line is None:
        return None

    if not isinstance(line, int) or isinstance(line, bool) or line < 1:
        return "must be a positive integer or null"

    full_path = os.path.join(tree, path)
    if not os.path.isfile(full_path):
        return None

    with open(full_path, "rb") as fh:
        line_count = sum(1 for _ in fh)

    if line > line_count:
        return f"{line} is past the end of {path} ({line_count} lines)"

    return None


def verdict(report):
    failing = [
        finding
        for finding in report.get("findings", [])
        if finding.get("severity") in FAILING
        and finding.get("confidence") == "confirmed"
    ]

    return "FAIL" if failing else "PASS"


def finding_id(finding):
    # Ignore line numbers so the ID survives nearby edits.
    claim = " ".join(str(finding.get("claim", "")).split()).lower()
    raw = f"{finding.get('file')}\x1f{claim}"

    return hashlib.sha256(raw.encode()).hexdigest()[:8]
