# shellcheck shell=bash

task_children() {
  local slug

  [ -n "${1:-}" ] || return 0

  for slug in $(task_slugs); do
    [ "$(task_field "$slug" CAP_PARENT)" = "$1" ] && printf '%s\n' "$slug"
  done

  return 0
}

task_pane() {
  awk -F= '$1=="CAP_PANE"{print $2}' "$TASKS/$1/task.env" 2>/dev/null
}

pane_live() {
  local pane

  pane=$(task_pane "$1")
  [ -n "$pane" ] && herdr pane get "$pane" >/dev/null 2>&1
}

agent_live() {
  pane_live "$1" && [ ! -e "$TASKS/$1/turns/exited" ]
}

pane_tail() {
  local pane

  pane=$(task_pane "$1")
  [ -n "$pane" ] && herdr pane read "$pane" --source visible --lines "${2:-60}" 2>/dev/null || true
}

pane_kill() {
  local pane

  pane=$(task_pane "$1")
  [ -n "$pane" ] && herdr pane close "$pane" >/dev/null 2>&1
}

# herdr has no backpressure, so large writes can lose text.
pane_send() {
  local pane text chunk_size i length

  pane=$(task_pane "$1")
  [ -n "$pane" ] || return 0

  text=$2
  chunk_size=400
  length=${#text}
  i=0

  while [ "$i" -lt "$length" ]; do
    herdr pane send-text "$pane" "${text:$i:$chunk_size}" >/dev/null 2>&1
    i=$((i + chunk_size))

    if [ "$i" -lt "$length" ]; then
      sleep 0.15
    fi
  done
}

pane_enter() {
  local pane

  pane=$(task_pane "$1")
  [ -n "$pane" ] && herdr pane send-keys "$pane" enter >/dev/null 2>&1 || true
}

# Some harnesses need more than one Enter before starting a turn.
pane_submit() {
  local slug=$1 text=$2 attempt

  pane_send "$slug" "$text"

  for attempt in 1 2 3; do
    sleep 0.4
    pane_enter "$slug"
    pane_wait_working "$slug" && return 0
  done

  return 1
}

pane_wait_working() {
  local slug=$1 attempt

  for attempt in 1 2 3 4 5 6; do
    sleep 1
    [ "$(pane_agent_status "$slug")" = working ] && return 0
  done

  return 1
}

pane_agent_status() {
  local pane

  pane=$(task_pane "$1")
  if [ -z "$pane" ]; then
    printf 'unknown'
    return
  fi

  herdr agent get "$pane" 2>/dev/null |
    jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null ||
    printf 'unknown'
}

pane_context_pct() {
  pane_tail "$1" 8 |
    grep -oiE '(context|ctx) [0-9]+% used' |
    tail -1 |
    grep -oE '[0-9]+' ||
    true
}

# watch is also an edge trigger: changed=1 is emitted once per new pane tail.
task_idle_age() {
  local watch=$TASKS/$1/watch hash

  hash=$(pane_tail "$1" 40 | cksum | cut -d' ' -f1)

  if [ -f "$watch" ] && [ "$(cut -d' ' -f1 "$watch")" = "$hash" ]; then
    printf '%s 0' "$(($(now) - $(cut -d' ' -f2 "$watch")))"
    return
  fi

  printf '%s %s\n' "$hash" "$(now)" >"$watch"
  printf '0 1'
}

# Keep this separate from task_idle_age so state polling cannot consume its edge.
task_state_stale_age() {
  local watch=$TASKS/$1/.task-state-watch hash

  hash=$(pane_tail "$1" 40 | cksum | cut -d' ' -f1)

  if [ -f "$watch" ] && [ "$(cut -d' ' -f1 "$watch")" = "$hash" ]; then
    printf '%s' "$(($(now) - $(cut -d' ' -f2 "$watch")))"
    return
  fi

  printf '%s %s\n' "$hash" "$(now)" >"$watch"
  printf 0
}

task_status_lines() {
  local file=$TASKS/$1/status.log
  local cursor=$TASKS/$1/status.cursor
  local start=0 line bytes pid read_from
  local LC_ALL=C

  [ -f "$file" ] || return 0

  if [ -f "$cursor" ]; then
    IFS= read -r start <"$cursor" || start=0

    case $start in
    '' | *[!0-9]*) start=0 ;;
    esac
  fi

  bytes=$(wc -c <"$file")
  [ "$start" -le "$bytes" ] || start=0
  read_from=$start

  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    start=$((start + ${#line} + 1))
  done < <(tail -c +$((read_from + 1)) "$file")
  pid=$!

  # A failed tail otherwise looks the same as an empty read.
  wait "$pid" || {
    warn "$1: could not read status.log past byte $read_from"
    return 0
  }

  printf '%s\n' "$start" >"$cursor"
}

task_status_verb() {
  case $1 in
  done:*) printf 'done' ;;
  blocked:*) printf 'blocked' ;;
  needs-input:*) printf 'needs-input' ;;
  failed:*) printf 'failed' ;;
  working:*) printf 'working' ;;
  esac
}

task_status_latest() {
  local file=$TASKS/$1/status.log
  local line verb latest=

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(task_status_verb "$line")
    [ -n "$verb" ] && latest=$verb
  done <"$file"

  if [ -n "$latest" ]; then
    printf '%s' "$latest"
  fi

  return 0
}

task_agent_state() {
  local slug=$1 status age

  if ! pane_live "$slug"; then
    printf exited
    return
  fi

  status=$(pane_agent_status "$slug")

  case $status in
  working | blocked)
    printf '%s' "$status"
    ;;
  idle | done)
    # herdr's done means idle with the result acknowledged.
    printf idle
    ;;
  *)
    # Fall back to output staleness when herdr cannot classify the harness.
    age=$(task_state_stale_age "$slug")
    if [ "$age" -ge "$CAP_IDLE_SECS" ]; then
      printf idle
    else
      printf working
    fi
    ;;
  esac
}

task_state() {
  local slug=$1 agent tree base verb

  agent=$(task_agent_state "$slug")

  case $agent in
  working | blocked)
    printf '%s' "$agent"
    return
    ;;
  esac

  if [ "$agent" != exited ]; then
    verb=$(task_status_latest "$slug" 2>/dev/null || true)

    case $verb in
    blocked | needs-input | failed)
      printf '%s' "$verb"
      return
      ;;
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
