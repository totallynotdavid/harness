# This module is sourced by bin/lib.sh. Keep its public helpers stable.
# shellcheck shell=bash
# shellcheck disable=SC2034

# One cap command per task at a time. Gate, check, commit, and land all
# read-modify-write state/tasks/<slug>/. Lock is released on process exit.
# Never blocks: refuses at once, naming whoever holds it. A caller whose
# job is delivery, not review or shipping, uses task_try_lock instead and
# decides for itself what to do when the task is busy.
task_lock() {
  local slug=$1
  task_try_lock "$slug" ||
    die "$slug is already held by $(cat "$TASKS/$slug/.lock" 2>/dev/null || echo 'another cap command')"
}

# Same lock, but returns 1 on contention instead of dying, so a caller that
# has somewhere else to put the work - cap-send's queue - can choose that
# instead of failing outright.
declare -A CAP_LOCK_FDS
declare -A CAP_LOCK_DEPTH
task_try_lock() {
  local slug=$1
  local dir=$TASKS/$slug
  # Same process already holds the real fd: one more frame is sharing it,
  # so task_unlock must see one more release before it actually closes
  # anything. Depth is process-local on purpose - CAP_LOCK_FDS never
  # survives into a child process either, so a child re-checking its
  # inherited CAP_LOCKS below has no depth of its own to track.
  if [ -n "${CAP_LOCK_FDS[$slug]:-}" ]; then
    CAP_LOCK_DEPTH[$slug]=$((${CAP_LOCK_DEPTH[$slug]:-1} + 1))
    return 0
  fi
  # Re-entrant: cap land can release via cap drop without deadlocking. The
  # marker is exported, so only the holder's children inherit it.
  case " ${CAP_LOCKS:-} " in *" $slug "*) return 0 ;; esac
  mkdir -p "$dir"
  local fd
  exec {fd}>>"$dir/.lock"
  flock -n "$fd" || {
    exec {fd}>&-
    return 1
  }
  printf 'pid %s (%s) since %s\n' "$$" "$(basename "$0")" "$(date -u +%H:%M:%SZ)" >"$dir/.lock"
  CAP_LOCKS="${CAP_LOCKS:-} $slug"
  export CAP_LOCKS
  CAP_LOCK_FDS[$slug]=$fd
  CAP_LOCK_DEPTH[$slug]=1

  task_pin_session
  task_arm_lock_exit_flush
}

# Pinned here, not inside session_identity: x=$(session_identity) always
# runs in a subshell, so an export inside it never reaches the caller, and
# cap-land shelling out to cap-drop needs the same identity under the same
# harness. caplib.py's launch_env_prefix/SCRUBBED strips CAP_SESSION the
# same as CAP_LOCKS, so a dispatched agent never sees it. Not locking
# itself, but every locker needs it done, once per process, the first time
# any lock is taken.
task_pin_session() {
  if [ -z "${CAP_SESSION:-}" ]; then
    CAP_SESSION=$(session_identity)
    export CAP_SESSION
  fi
}

# Flushes this task's queue the moment this process's hold on it ends,
# never mid-review or mid-rebase. Registered once per process, so a
# second slug locked here does not queue a second flush of the first.
# A kill instead of a clean exit skips this trap; the flock still
# releases at the kernel level, and the message waits for whichever
# later holder locks this slug and exits cleanly.
task_arm_lock_exit_flush() {
  if [ -z "${CAP_LOCK_EXIT_ARMED:-}" ]; then
    CAP_LOCK_EXIT_ARMED=1
    cap_exit_add task_flush_locks_on_exit
  fi
}

task_flush_locks_on_exit() {
  local slug
  for slug in ${CAP_LOCKS:-}; do queue_flush "$slug" || true; done
}

# Releases a lock task_try_lock took, bare - no flush. For a path that
# never did any work on the task (task_owner_free said no), so a message
# queued against it waits for that task's own live owner instead of being
# typed by a session that just declined to touch it. Every path that did
# do the work calls task_release below instead, never this directly.
task_unlock() {
  local slug=$1 fd
  fd=${CAP_LOCK_FDS[$slug]:-}
  # No fd recorded means task_try_lock's re-entrant branch fired without
  # ever sharing this process's own fd: some other still-active frame
  # holds the real lock, not this call, so there is nothing here to release.
  [ -n "$fd" ] || return 0
  # A depth above 1 means another frame in this same process is still
  # sharing that fd (task_try_lock's same-process re-entrant branch) - only
  # the frame that brings depth back to 0 actually closes it.
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

# The one place that pairs flush with unlock, for every site that held
# this task's own lock to do its own real work on it: releasing without
# flushing first strands a message queued while the work was in progress,
# since task_unlock strips the slug from CAP_LOCKS before the exit trap
# ever gets a look at it.
task_release() {
  queue_flush "$1" || true
  task_unlock "$1"
}
