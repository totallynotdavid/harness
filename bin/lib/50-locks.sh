# shellcheck shell=bash

declare -A CAP_LOCK_FDS
declare -A CAP_LOCK_DEPTH

# Refuses instead of waiting when another process holds the task.
task_lock() {
  local slug=$1

  task_try_lock "$slug" ||
    die "$slug is already held by $(cat "$TASKS/$slug/.lock" 2>/dev/null || echo 'another cap command')"
}

task_try_lock() {
  local slug=$1
  local dir=$TASKS/$slug
  local fd

  if [ -n "${CAP_LOCK_FDS[$slug]:-}" ]; then
    CAP_LOCK_DEPTH[$slug]=$((${CAP_LOCK_DEPTH[$slug]:-1} + 1))
    return 0
  fi

  # Child processes inherit CAP_LOCKS but not the fd stored in CAP_LOCK_FDS.
  case " ${CAP_LOCKS:-} " in
  *" $slug "*) return 0 ;;
  esac

  mkdir -p "$dir"
  exec {fd}>>"$dir/.lock"

  if ! flock -n "$fd"; then
    exec {fd}>&-
    return 1
  fi

  printf 'pid %s (%s) since %s\n' \
    "$$" "$(basename "$0")" "$(date -u +%H:%M:%SZ)" >"$dir/.lock"

  CAP_LOCKS="${CAP_LOCKS:-} $slug"
  export CAP_LOCKS

  CAP_LOCK_FDS[$slug]=$fd
  CAP_LOCK_DEPTH[$slug]=1

  task_pin_session
  task_arm_lock_exit_flush
}

task_pin_session() {
  if [ -n "${CAP_SESSION:-}" ]; then
    return
  fi

  # session_identity usually runs through command substitution, so it cannot
  # export CAP_SESSION back to its caller.
  CAP_SESSION=$(session_identity)
  export CAP_SESSION
}

task_arm_lock_exit_flush() {
  if [ -n "${CAP_LOCK_EXIT_ARMED:-}" ]; then
    return
  fi

  CAP_LOCK_EXIT_ARMED=1
  cap_exit_add task_flush_locks_on_exit
}

task_flush_locks_on_exit() {
  local slug

  for slug in ${CAP_LOCKS:-}; do
    queue_flush "$slug" || true
  done
}

# Does not flush the queue. Use when this process locked the task but did no work.
task_unlock() {
  local slug=$1
  local fd=${CAP_LOCK_FDS[$slug]:-}

  # An inherited CAP_LOCKS entry has no fd for this process to release.
  [ -n "$fd" ] || return 0

  if [ "${CAP_LOCK_DEPTH[$slug]:-1}" -gt 1 ]; then
    CAP_LOCK_DEPTH[$slug]=$((CAP_LOCK_DEPTH[$slug] - 1))
    return 0
  fi

  unset 'CAP_LOCK_DEPTH[$slug]'

  exec {fd}>&-
  unset 'CAP_LOCK_FDS[$slug]'

  CAP_LOCKS=" ${CAP_LOCKS:-} "
  CAP_LOCKS=${CAP_LOCKS/ $slug / }
  CAP_LOCKS=${CAP_LOCKS# }
  CAP_LOCKS=${CAP_LOCKS% }
}

# Flush before unlocking so messages queued during the work are not stranded.
task_release() {
  queue_flush "$1" || true
  task_unlock "$1"
}
