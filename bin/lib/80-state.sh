# This module is sourced by bin/lib.sh. Keep its public helpers stable.
# shellcheck shell=bash
# shellcheck disable=SC2034

task_children() {
  local s
  [ -n "${1:-}" ] || return 0
  for s in $(task_slugs); do
    [ "$(task_field "$s" CAP_PARENT)" = "$1" ] && printf '%s\n' "$s"
  done
  return 0
}
task_pane() { awk -F= '$1=="CAP_PANE"{print $2}' "$TASKS/$1/task.env" 2>/dev/null; }

pane_live() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane get "$p" >/dev/null 2>&1
}

# Whether the task's agent session is still running. Its pane outlives it:
# the shell the session ran in stays open, so a live pane is not enough, and
# the exit marker cap-launch's session writes on its way out says the rest.
agent_live() {
  pane_live "$1" && [ ! -e "$TASKS/$1/turns/exited" ]
}
pane_tail() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane read "$p" --source visible --lines "${2:-60}" 2>/dev/null || true
}
pane_kill() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane close "$p" >/dev/null 2>&1
}

# Send text without pressing Enter. Split into chunks because herdr pane
# send-text has no backpressure and target TUI can drop large messages
# mid-word. Chunk size and pause are empirically safe margins below observed
# drop threshold.
pane_send() {
  local p text chunk_size i n
  p=$(task_pane "$1")
  [ -n "$p" ] || return 0
  text=$2
  chunk_size=400
  n=${#text}
  i=0
  while [ "$i" -lt "$n" ]; do
    herdr pane send-text "$p" "${text:$i:$chunk_size}" >/dev/null 2>&1
    i=$((i + chunk_size))
    if [ "$i" -lt "$n" ]; then
      sleep 0.15
    fi
  done
}
pane_enter() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane send-keys "$p" enter >/dev/null 2>&1 || true
}

# Types text in once, then presses Enter up to 3 times, checking after each
# for a turn to start via pane_wait_working, not whether the text is still
# visible: a short message, or one the harness echoes back, would make that
# match forever.
pane_submit() {
  local slug=$1 text=$2 _
  pane_send "$slug" "$text"
  for _ in 1 2 3; do
    sleep 0.4
    pane_enter "$slug"
    pane_wait_working "$slug" && return 0
  done
  return 1
}

# Whether a turn actually began, not just whether text left the input box.
pane_wait_working() {
  local slug=$1 i
  for i in 1 2 3 4 5 6; do
    sleep 1
    [ "$(pane_agent_status "$slug")" = working ] && return 0
  done
  return 1
}

# herdr's reported status, not a guess from output staleness.
pane_agent_status() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] || { printf 'unknown'; return; }
  herdr agent get "$p" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null ||
    printf 'unknown'
}

# The context-used percentage from the pane's own status line, whichever
# harness's format it is in ("Context 46% used" from codex, "ctx 37% used"
# from claude). Empty if none is visible yet.
pane_context_pct() {
  # Under set -e/pipefail, an unmatched grep here would fail the whole
  # pipeline and kill the caller's script, not just return empty as the
  # comment above promises.
  pane_tail "$1" 8 | grep -oiE '(context|ctx) [0-9]+% used' | tail -1 | grep -oE '[0-9]+' || true
}

# A task is idle when its recent output stops changing. Not a read: it
# rewrites state/tasks/<slug>/watch and reports changed=1 exactly once per
# change, an edge bin/cap-watch consumes to know when to re-arm $reported.
task_idle_age() {
  local w=$TASKS/$1/watch h
  h=$(pane_tail "$1" 40 | cksum | cut -d' ' -f1)

  if [ -f "$w" ] && [ "$(cut -d' ' -f1 "$w")" = "$h" ]; then
    printf '%s 0' "$(($(now) - $(cut -d' ' -f2 "$w")))"
  else
    printf '%s %s\n' "$h" "$(now)" >"$w"
    printf '0 1'
  fi
}

# Same signal as task_idle_age - has the pane's tail stopped changing - but
# tracked in its own file, never state/tasks/<slug>/watch: task_state below
# polls on every captain turn, and sharing task_idle_age's file would eat
# the changed=1 edge cap-watch depends on to re-arm $reported. Only reached
# when herdr itself cannot classify the agent (case *) below), which is
# rare, so a second small tracker file per task costs little.
task_state_stale_age() {
  local w=$TASKS/$1/.task-state-watch h
  h=$(pane_tail "$1" 40 | cksum | cut -d' ' -f1)

  if [ -f "$w" ] && [ "$(cut -d' ' -f1 "$w")" = "$h" ]; then
    printf '%s' "$(($(now) - $(cut -d' ' -f2 "$w")))"
  else
    printf '%s %s\n' "$h" "$(now)" >"$w"
    printf 0
  fi
}

# Read complete status lines appended since the task's last status check.
task_status_lines() {
  local f=$TASKS/$1/status.log cursor start line bytes pid read_from
  local LC_ALL=C

  [ -f "$f" ] || return 0

  cursor=$TASKS/$1/status.cursor
  start=0
  if [ -f "$cursor" ]; then
    IFS= read -r start <"$cursor" || start=0
    case $start in
      ''|*[!0-9]*) start=0 ;;
    esac
  fi

  bytes=$(wc -c <"$f")
  [ "$start" -le "$bytes" ] || start=0
  read_from=$start

  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    start=$((start + ${#line} + 1))
  done < <(tail -c +$((read_from + 1)) "$f")
  pid=$!
  # A failed tail is invisible to the loop above: zero iterations reads the
  # same as nothing new logged. Caught here instead of moving the cursor
  # past a read that never happened.
  wait "$pid" || { warn "$1: could not read status.log past byte $read_from"; return 0; }

  printf '%s\n' "$start" >"$cursor"
}

task_status_verb() {
  case $1 in
    done:*)       printf 'done' ;;
    blocked:*)    printf 'blocked' ;;
    needs-input:*) printf 'needs-input' ;;
    failed:*)     printf 'failed' ;;
    working:*)    printf 'working' ;;
  esac
}

# Return the latest recognized status event in the task's append-only log.
task_status_latest() {
  local f=$TASKS/$1/status.log line verb latest=
  [ -f "$f" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(task_status_verb "$line")
    [ -n "$verb" ] && latest=$verb
  done <"$f"

  if [ -n "$latest" ]; then
    printf '%s' "$latest"
  fi
}

# Whether the agent itself is running, per herdr - never a word an agent
# chose. idle covers both herdr's "idle" and "done": they differ only in
# whether a client has acknowledged it, not in whether the agent is
# running. Falls back to whether the pane's visible output has changed
# recently (task_state_stale_age) only when herdr cannot classify it at
# all (unknown, or a harness herdr does not instrument).
task_agent_state() {
  local slug=$1 agent age
  pane_live "$slug" || { printf exited; return; }
  agent=$(pane_agent_status "$slug")
  case $agent in
    working | blocked) printf '%s' "$agent" ;;
    idle | done) printf idle ;;
    *)
      age=$(task_state_stale_age "$slug")
      if [ "$age" -ge "$CAP_IDLE_SECS" ]; then printf idle; else printf working; fi
      ;;
  esac
}

# One helper answers "what state is this task in": task_agent_state
# decides whether it is working, git and gate.json decide what is ready,
# and the log is consulted only to name why it stopped. See
# docs/pipeline-notes.md, "Task state is not a log word".
task_state() {
  local slug=$1 agent tree base verb

  agent=$(task_agent_state "$slug")
  case $agent in
    working | blocked) printf '%s' "$agent"; return ;;
  esac

  # herdr has now settled *whether* it stopped; the log is read only for
  # *why*, and only for the three verbs that carry one - a bare "done" or
  # nothing logged at all is not a reason, so it falls through to ready
  # (git/gate.json) or the bare stopped state below. Skipped once exited: a
  # dead pane's old log verb never gets to override the agent being gone.
  if [ "$agent" != exited ]; then
    verb=$(task_status_latest "$slug" 2>/dev/null || true)
    case $verb in
      blocked | needs-input | failed) printf '%s' "$verb"; return ;;
    esac
  fi

  tree=$(task_field "$slug" CAP_TREE 2>/dev/null || true)
  base=$(task_field "$slug" CAP_BASE 2>/dev/null || true)
  if [ -n "$tree" ] && gate_ready "$slug" "$tree" "$base"; then
    printf ready
    return
  fi

  printf '%s' "$agent"
}
