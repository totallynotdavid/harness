# This module is sourced by bin/lib.sh. Keep its public helpers stable.
# shellcheck shell=bash
# shellcheck disable=SC2034

# Read a task field without sourcing its record.
task_field() {
  local f=$TASKS/$1/task.env
  [ -f "$f" ] || return 1
  awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/, ""); print; exit}' "$f"
}

# Update a task field without reordering the record.
task_env_set() {
  local f=$TASKS/$1/task.env tmp
  [ -f "$f" ] || die "no such task '$1'"
  tmp=$(mktemp)
  awk -F= -v k="$2" -v v="$3" '
    $1==k { print k "=" v; seen=1; next }
    { print }
    END { if (!seen) print k "=" v }
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

# The pid of the nearest claude or codex ancestor of $1 (default: this
# process), found by walking proc(5) field 2 (ppid) up from there. Empty
# with no such ancestor - a plain shell can live for days and is never an
# agent. Factored out of session_identity so cwd-based agent detection
# below can use the raw pid without going through CAP_SESSION's cache.
harness_ancestor_pid() {
  local pid=${1:-$$} comm
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

# The identity of the session that ran this cap command: CAP_SESSION if
# task_lock already pinned one, else harness_ancestor_pid's find, as
# "<pid>@<start-time>" (proc(5) field 20). Empty with no such ancestor - a
# plain shell can live for days, and treating it as owner would block every
# later harness session from the task indefinitely. Every caller here reads
# a missing owner as safe, not as a shell's.
session_identity() {
  if [ -n "${CAP_SESSION:-}" ]; then
    printf '%s' "$CAP_SESSION"
    return 0
  fi

  local pid stamp id=""
  pid=$(harness_ancestor_pid) || true
  if [ -n "$pid" ]; then
    stamp=$(proc_stat_field "$pid" 20 2>/dev/null || true)
    [ -n "$stamp" ] && id="$pid@$stamp"
  fi

  printf '%s' "$id"
}

# A status.log-ready label for a session_identity id (or a bare pid, as
# stored in the send queue): "pid N", or a name that still says something
# when there is no pid, rather than an unactionable blank ("sent by pid : ...").
session_label() {
  local pid=${1%@*}
  if [ -n "$pid" ]; then printf 'pid %s' "$pid"; else printf 'an unidentified session'; fi
}

# Whether an id from session_identity still names a running process. pids
# get reused, so this also checks the recorded start time, not just pid
# occupancy - and a transient failure to read /proc/<pid>/stat answers
# "still alive," never "dead": an access-control decision must not treat
# "could not tell" as license to reclaim a task with no --take. Only
# /proc/<pid> itself being gone is treated as the process having exited.
session_alive() {
  local id=$1 pid=${1%@*} stamp=${1#*@} live
  [ -n "$id" ] && [ "$pid" != "$id" ] && [ -n "$stamp" ] || return 1
  [ -e "/proc/$pid" ] || return 1
  live=$(proc_stat_field "$pid" 20 2>/dev/null || true)
  [ -z "$live" ] && return 0
  [ "$live" = "$stamp" ]
}

# Whether harness pid $2 (or $1's own, if omitted) has slug's worktree as
# its cwd. cap spawn always launches there, and unlike CAP_TASK - set only
# at first launch, so it does not survive `claude --resume` - cwd is read
# fresh from /proc every time, from outside the process too: a captain or
# a different agent checking a stored owner pid, since session_identity
# alone cannot tell those claude processes apart. Unreadable answers no.
agent_cwd_matches() {
  local slug=$1 pid=$2 tree cwd
  tree=$(task_field "$slug" CAP_TREE 2>/dev/null) || return 1
  [ -n "$tree" ] && [ -n "$pid" ] && [ -r "/proc/$pid/cwd" ] || return 1
  cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || return 1
  [ "$cwd" = "$(readlink -f "$tree" 2>/dev/null)" ]
}

# Whether this process is the agent cap-spawn dispatched into slug.
task_dispatched_here() {
  local pid
  pid=$(harness_ancestor_pid) || return 1
  agent_cwd_matches "$1" "$pid"
}

# True when the task is free for this caller to touch: unowned, dead-owned,
# or owned by the caller itself or its own dispatched agent. False
# otherwise, naming nobody - task_owner_check wraps this to die with the
# pid; stack_sync_task uses this directly to degrade on a conflict instead
# of exiting. --take carries no mode into this API (rules/code.md): a
# caller that got it calls task_owner_take directly instead, skipping this.
task_owner_free() {
  local slug=$1 owner me
  task_dispatched_here "$slug" && return 0
  owner=$(task_field "$slug" CAP_OWNER 2>/dev/null || true)
  me=$(session_identity)
  # session_alive is the only thing that compares the recorded start-time
  # against whatever is actually running at that pid now. A cwd match on
  # the bare pid alone - dropped from here - proves nothing: a reused pid
  # whose cwd happens to be the task's worktree, the task's own freshly
  # launched agent or a shell someone cd'd there, is not the recorded
  # owner just because it occupies the same pid number.
  [ -n "$owner" ] && [ "$owner" != "$me" ] && session_alive "$owner" || return 0
  return 1
}

# Refuses a mutating command when the task is owned by a live session other
# than the caller, naming the pid so the captain can look. Read-only,
# unlike task_owner_claim below, so it is safe to call without the lock -
# cap-send uses it to gate queueing too.
task_owner_check() {
  local slug=$1
  task_owner_free "$slug" ||
    die "$slug is owned by pid $(task_field "$slug" CAP_OWNER 2>/dev/null | cut -d@ -f1)"
}

# Records the caller as owner, unconditionally - skipped for a plain shell
# (see session_identity) and for the task's own dispatched agent
# (task_dispatched_here), since an agent naming itself owner of its own
# task would block its own captain from it. What a --take caller calls
# directly, and what task_owner_claim below calls after checking.
task_owner_take() {
  local slug=$1 me
  task_dispatched_here "$slug" && return 0
  me=$(session_identity)
  [ -n "$me" ] || return 0
  task_env_set "$slug" CAP_OWNER "$me"
}

# task_owner_check then task_owner_take. Call after task_lock: checking
# first lets two sessions each write themselves in as owner before either
# has done any work.
task_owner_claim() {
  task_owner_check "$1"
  task_owner_take "$1"
}
