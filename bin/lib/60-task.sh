# shellcheck shell=bash

task_field() {
  local file=$TASKS/$1/task.env
  [ -f "$file" ] || return 1

  awk -F= -v key="$2" '$1==key{sub(/^[^=]*=/, ""); print; exit}' "$file"
}

task_env_set() {
  local file=$TASKS/$1/task.env
  local tmp

  [ -f "$file" ] || die "no such task '$1'"

  tmp=$(mktemp)
  awk -F= -v key="$2" -v value="$3" '
    $1==key { print key "=" value; seen=1; next }
    { print }
    END { if (!seen) print key "=" value }
  ' "$file" >"$tmp"

  mv "$tmp" "$file"
}

harness_ancestor_pid() {
  local pid=${1:-$$}
  local comm

  while [ "$pid" -gt 1 ] 2>/dev/null; do
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)

    if [ "$comm" = claude ] || [ "$comm" = codex ]; then
      printf '%s' "$pid"
      return 0
    fi

    pid=$(proc_stat_field "$pid" 2 2>/dev/null || true)
    [ -n "$pid" ] || break
  done

  return 1
}

session_identity() {
  if [ -n "${CAP_SESSION:-}" ]; then
    printf '%s' "$CAP_SESSION"
    return 0
  fi

  local pid
  local stamp

  pid=$(harness_ancestor_pid) || return 0
  stamp=$(proc_stat_field "$pid" 20 2>/dev/null || true)
  [ -n "$stamp" ] || return 0

  printf '%s@%s' "$pid" "$stamp"
}

session_label() {
  local pid=${1%@*}

  if [ -n "$pid" ]; then
    printf 'pid %s' "$pid"
  else
    printf 'an unidentified session'
  fi
}

session_alive() {
  local id=$1
  local pid=${1%@*}
  local stamp=${1#*@}
  local live

  [ -n "$id" ] || return 1
  [ "$pid" != "$id" ] || return 1
  [ -n "$stamp" ] || return 1
  [ -e "/proc/$pid" ] || return 1

  live=$(proc_stat_field "$pid" 20 2>/dev/null || true)

  # A failed /proc read must not allow another session to reclaim the task.
  [ -z "$live" ] && return 0

  [ "$live" = "$stamp" ]
}

agent_cwd_matches() {
  local slug=$1
  local pid=$2
  local tree
  local cwd

  tree=$(task_field "$slug" CAP_TREE 2>/dev/null) || return 1

  [ -n "$tree" ] || return 1
  [ -n "$pid" ] || return 1
  [ -r "/proc/$pid/cwd" ] || return 1

  cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || return 1
  tree=$(readlink -f "$tree" 2>/dev/null) || return 1

  [ "$cwd" = "$tree" ]
}

task_dispatched_here() {
  local pid

  pid=$(harness_ancestor_pid) || return 1
  agent_cwd_matches "$1" "$pid"
}

task_forbid_self_dispatch() {
  local slug=$1 command=$2

  task_dispatched_here "$slug" &&
    die "$slug's own agent cannot run $command; leave the worktree uncommitted for Captain to review and commit"

  return 0
}

task_owner_free() {
  local slug=$1
  local owner
  local me

  task_dispatched_here "$slug" && return 0

  owner=$(task_field "$slug" CAP_OWNER 2>/dev/null || true)
  [ -n "$owner" ] || return 0

  me=$(session_identity)
  [ "$owner" = "$me" ] && return 0

  # The start time distinguishes the recorded owner from a reused PID.
  session_alive "$owner" || return 0

  return 1
}

task_owner_check() {
  local slug=$1
  local owner

  task_owner_free "$slug" && return 0

  owner=$(task_field "$slug" CAP_OWNER 2>/dev/null)
  die "$slug is owned by pid ${owner%@*}"
}

task_owner_take() {
  local slug=$1
  local me

  # The dispatched agent must not claim the task from its captain.
  task_dispatched_here "$slug" && return 0

  me=$(session_identity)
  [ -n "$me" ] || return 0

  task_env_set "$slug" CAP_OWNER "$me"
}

task_owner_claim() {
  task_owner_check "$1"
  task_owner_take "$1"
}
