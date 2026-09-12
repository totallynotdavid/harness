# bin/lib.sh - shared helpers for cap commands.
# shellcheck shell=bash
# shellcheck disable=SC2034 # globals here are read by the bin/cap-* scripts that source this file

set -euo pipefail

CAP_HOME=${CAP_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export CAP_HOME

# CAP_BIN: which code is running, always this file's own directory -
# distinct from CAP_HOME, which may point elsewhere in a worktree.
CAP_BIN=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
export CAP_BIN

# shellcheck source=config/captain.conf
. "$CAP_HOME/config/captain.conf"

PROJECTS=$CAP_HOME/config/projects.tsv
TASKS=$CAP_HOME/state/tasks

die() {
  printf 'cap: %s\n' "$*" >&2
  exit 1
}
warn() { printf 'cap: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s; }
stamp() { date +%Y-%m-%d; }

# A session id for a headless harness launch. uuidgen is not guaranteed
# present, so this falls back to the kernel's own generator; die with a
# reason rather than let a missing fallback exit callers silently under set -e.
new_uuid() {
  if have uuidgen; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    die "no uuid source on this host (need uuidgen or /proc/sys/kernel/random/uuid)"
  fi
}

# projects.tsv: name, path, mode, model.

proj_field() {
  [ -f "$PROJECTS" ] || die "no registry; run: cap map --sync"
  awk -F'\t' -v n="$1" -v c="$2" '$1==n {print $c; found=1} END{exit !found}' "$PROJECTS" ||
    die "unknown project '$1' (cap map --sync to register)"
}
proj_path() { proj_field "$1" 2; }
proj_mode() {
  m=$(proj_field "$1" 3)
  printf '%s' "${m:-pr}"
}
proj_model() { proj_field "$1" 4; }

task_dir() { printf '%s/%s' "$TASKS" "$1"; }
task_load() {
  local f=$TASKS/$1/task.env
  [ -f "$f" ] || die "no such task '$1'"

  # shellcheck disable=SC1090
  . "$f"
}
task_slugs() { [ -d "$TASKS" ] && ls -1 "$TASKS" 2>/dev/null || true; }

# Make worktree usable before agent starts. Worktrees have no dependencies
# (node_modules is ignored). Runs every ecosystem's installer whose lockfile
# is present - JS, Python, Rust, Go, Ruby, PHP can all fire in one call.
# bun runs independently of the rest of the JS chain, so a repo with both
# bun.lock and package-lock.json runs both installers. Within pnpm/yarn/npm,
# and within uv/poetry, only the first matching lockfile runs.

preflight_deps() {
  local tree=$1 ran=0

  if [ -f "$tree/mise.toml" ] && have mise; then
    mise trust --yes "$tree/mise.toml" >/dev/null 2>&1 || true
    (cd "$tree" && mise install -y) && ran=1
  fi
  if [ -f "$tree/bun.lock" ] || [ -f "$tree/bun.lockb" ]; then
    have bun && (cd "$tree" && bun install --frozen-lockfile) && ran=1
  fi
  if [ -f "$tree/pnpm-lock.yaml" ]; then
    have pnpm && (cd "$tree" && pnpm install --frozen-lockfile) && ran=1
  elif [ -f "$tree/yarn.lock" ]; then
    have yarn && (cd "$tree" && yarn install --immutable) && ran=1
  elif [ -f "$tree/package-lock.json" ]; then
    have npm && (cd "$tree" && npm ci) && ran=1
  fi
  if [ -f "$tree/uv.lock" ]; then
    have uv && (cd "$tree" && uv sync) && ran=1
  elif [ -f "$tree/poetry.lock" ]; then
    have poetry && (cd "$tree" && poetry install) && ran=1
  fi
  [ ! -f "$tree/Cargo.lock" ] || { have cargo && (cd "$tree" && cargo fetch) && ran=1; }
  [ ! -f "$tree/go.sum" ] || { have go && (cd "$tree" && go mod download) && ran=1; }
  [ ! -f "$tree/Gemfile.lock" ] || { have bundle && (cd "$tree" && bundle install) && ran=1; }
  [ ! -f "$tree/composer.lock" ] || { have composer && (cd "$tree" && composer install) && ran=1; }

  # A project whose setup cannot be inferred is not a project to refuse. Say
  # nothing and let the agent start.
  [ "$ran" = 1 ]
}

# Tools a project needs that nothing in the project declares. Lives in Captain
# (not the project) because Captain is cloned to other machines and most
# projects are clones nobody should restructure. One file per project, kind
# then argument per line:
#   config/tools/<project>
#     mise podman
#     mise php@8.4
#     sh   sudo apt-get install -y poppler-utils
preflight_tools() {
  local project=$1 kind rest
  local f=$CAP_HOME/config/tools/$project
  [ -f "$f" ] || return 0

  while read -r kind rest; do
    case ${kind:-} in
    '' | \#*) continue ;;
    mise)
      have mise || { warn "mise is not installed; cannot provide $rest"; continue; }
      have "${rest%%@*}" && continue
      mise use -g "$rest" || warn "could not install $rest"
      ;;
    sh)
      have "$(printf '%s' "$rest" | awk '{print $NF}')" && continue
      eval "$rest" || warn "could not run: $rest"
      ;;
    *) warn "$f: unknown kind '$kind'" ;;
    esac
  done <"$f"
}

# Which commits the project's own tooling has actually passed on. cap-spawn
# reads this to refuse forking a second task from a base nothing has verified.
VERIFIED=$CAP_HOME/state/verified

verified_record() {
  local project=$1 sha=$2
  [ -n "$sha" ] || return 0
  mkdir -p "$VERIFIED/$project"
  : >"$VERIFIED/$project/$sha"
}

verified_is() {
  local project=$1 sha=$2
  [ -n "$sha" ] && [ -f "$VERIFIED/$project/$sha" ]
}

# One `cap verify --repo` per project's shared checkout at a time - it runs
# builds and tests directly in proj_path, not a worktree, so two runs (or
# one racing hand-edits) would step on the same tree.
project_lock() {
  local project=$1 dir fd
  dir=$VERIFIED/$project
  mkdir -p "$dir"
  exec {fd}>>"$dir/.lock"
  flock -n "$fd" ||
    die "$project is already being verified by $(cat "$dir/.lock" 2>/dev/null || echo 'another cap verify --repo')"
  printf 'pid %s (%s) since %s\n' "$$" "$(basename "$0")" "$(date -u +%H:%M:%SZ)" >"$dir/.lock"
}

# What one task of a project actually costs in memory, measured from a real
# cap-verify run (project_peak_record below) rather than guessed, so the
# CAP_MIN_FREE_MB default only ever covers a project that hasn't run yet.
# Parallelism is faster only while every task's working set fits at once.
PEAKS=$CAP_HOME/state/peaks

project_peak_mb() {
  local f=$PEAKS/$1 v=""
  [ -f "$f" ] && v=$(cat "$f" 2>/dev/null || true)
  case $v in
  '' | *[!0-9]*) printf '%s' "${CAP_MIN_FREE_MB:-1200}" ;;
  *) printf '%s' "$v" ;;
  esac
}

# Keep the high-water mark, never the latest reading. A run that happened to be
# cheap must not license a fan-out the expensive run cannot survive.
project_peak_record() {
  local project=$1 mb=$2 cur=0
  case $mb in '' | *[!0-9]*) return 0 ;; esac
  mkdir -p "$PEAKS"
  # Compare against what was recorded, never against the fallback. Comparing
  # with project_peak_mb means a first real reading below the default is
  # discarded and the guess survives forever.
  cur=$(cat "$PEAKS/$project" 2>/dev/null || echo 0)
  case $cur in '' | *[!0-9]*) cur=0 ;; esac
  if [ "$mb" -gt "$cur" ]; then printf '%s\n' "$mb" >"$PEAKS/$project"; fi
}

# How many more tasks this box can hold for a project, right now.
project_slots() {
  local project=$1 avail peak
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  peak=$(project_peak_mb "$project")
  [ "$peak" -gt 0 ] || peak=1200
  printf '%s' "$((avail / peak))"
}

# The project a wave file names in its header.
wave_project() {
  sed -n 's/^#[[:space:]]*project:[[:space:]]*//p' "$1" 2>/dev/null | head -1
}

# Path ownership guard prevents collisions across tasks. Tasks declare paths
# in state/tasks/<slug>/owns (one per line), never in task.env (which is sourced
# and would parse multi-glob as shell). Globs use git's :(glob) pathspec.

owns_read() {
  local f=$TASKS/$1/owns
  [ -f "$f" ] || return 0
  tr '\n' ' ' <"$f" | sed 's/  */ /g; s/^ //; s/ $//'
}

owns_write() {
  local slug=$1
  shift
  mkdir -p "$TASKS/$slug"
  printf '%s\n' "$@" >"$TASKS/$slug/owns"
}

# The literal prefix of a glob, up to the first wildcard. Two globs whose
# prefixes contain one another can collide on a file that does not exist yet,
# which is what .env.example did.
owns_prefix() {
  local g=${1%%[*?[]*}
  printf '%s' "${g%/}"
}

# Every file in a worktree that a glob set claims, tracked and untracked alike.
owns_files() {
  local tree=$1 g
  shift
  for g in "$@"; do
    git -C "$tree" ls-files -co --exclude-standard -- ":(glob)$g" 2>/dev/null || true
  done | sort -u
}

# Print what two glob sets share and return 0, or return 1 when they are
# disjoint. Concrete files first, then prefixes for ground neither has touched.
owns_overlap() {
  local tree=$1 shared pa pb
  local -a a b
  read -r -a a <<<"$2"
  read -r -a b <<<"$3"
  [ "${#a[@]}" -gt 0 ] && [ "${#b[@]}" -gt 0 ] || return 1

  shared=$(comm -12 \
    <(owns_files "$tree" "${a[@]}") \
    <(owns_files "$tree" "${b[@]}") 2>/dev/null || true)
  if [ -n "$shared" ]; then
    printf '%s\n' "$shared"
    return 0
  fi

  for pa in "${a[@]}"; do
    pa=$(owns_prefix "$pa")/
    for pb in "${b[@]}"; do
      pb=$(owns_prefix "$pb")/
      case $pa in "$pb"*) printf '%s overlaps %s\n' "${pa%/}" "${pb%/}"; return 0 ;; esac
      case $pb in "$pa"*) printf '%s overlaps %s\n' "${pa%/}" "${pb%/}"; return 0 ;; esac
    done
  done
  return 1
}

# Glob to anchored regex per git's :(glob) rules: ** crosses dirs, * does not.
# No wildcard means directory claim (everything under it) so regex matches both
# the dir itself and files inside it, not just `^dir$`.
owns_regex() {
  case $1 in
  *[*?]*) ;;
  *) printf '^%s(/.*)?$' "$(printf '%s' "$1" | sed 's/[].^$+(){}|\[]/\\&/g')"; return ;;
  esac
  printf '%s' "$1" | awk '{
    out = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "*") {
        if (substr($0, i + 1, 1) == "*") { out = out ".*"; i++ }
        else { out = out "[^/]*" }
      } else if (c == "?") { out = out "[^/]" }
      else if (index(".^$+(){}[]|\\", c) > 0) { out = out "\\" c }
      else { out = out c }
    }
    print "^" out "$"
  }'
}

# Whether a repository-relative path falls inside a glob set.
owns_claims() {
  local path=$1 g
  shift
  for g in "$@"; do
    if printf '%s\n' "$path" | grep -qE "$(owns_regex "$g")"; then
      return 0
    fi
  done
  return 1
}

# Whether any live task in the same project already claims this ground. Prints
# the claimants and returns 0 when it finds one.
owns_taken() {
  local project=$1 tree=$2 globs=$3 self=${4:-} other otree hit found=1
  for other in $(task_slugs); do
    [ "$other" != "$self" ] || continue
    [ "$(task_field "$other" CAP_PROJECT 2>/dev/null || true)" = "$project" ] || continue
    otree=$(task_field "$other" CAP_TREE 2>/dev/null || true)
    [ -n "$otree" ] && [ -e "$otree/.git" ] || continue
    hit=$(owns_overlap "$tree" "$globs" "$(owns_read "$other")") || continue
    printf '%s claims:\n' "$other"
    printf '%s\n' "$hit" | sed 's/^/    /'
    found=0
  done
  return $found
}

# A field of /proc/<pid>/stat, numbered from 1 (state) the way proc(5)
# numbers them after the process name: 2 is ppid, 20 is starttime. The name
# can itself contain spaces or a ")", which would shift every plain
# whitespace-split field after it, so this strips through the LAST ")"
# first - the name is the only field that can hold one, so the rest split
# safely from there.
proc_stat_field() {
  local pid=$1 n=$2 raw rest
  local -a fields
  raw=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  rest=${raw##*)}
  read -r -a fields <<<"$rest"
  printf '%s' "${fields[$((n - 1))]:-}"
}

# trap CMD EXIT composes here instead of overwriting: every EXIT trap from
# here on appends to CAP_EXIT_FNS and runs in order, so task_try_lock's own
# exit hook survives whatever a caller sets afterwards with a plain `trap`.
CAP_EXIT_FNS=()

# BASHPID, the real OS pid, changes inside a subshell even though $$ does
# not - a subshell that never calls trap itself never re-runs the parent's
# inherited CAP_EXIT_FNS at its own exit; one that does starts its own list.
CAP_EXIT_PID=""
trap() {
  # Composes only `trap CMD SIG...` where CMD is a real command and EXIT
  # is among SIG. `trap - EXIT` and `trap '' EXIT` both reach the builtin
  # unchanged and forget this process's composed handlers, so a later
  # `trap CMD EXIT` starts fresh instead of resurrecting what was just
  # cancelled. A flag like `trap -p EXIT` or `trap -l` is a query and
  # touches no state at all.
  local sig has_exit=0 other=() compose=0 reset_exit=0
  if [ "$#" -ge 2 ]; then
    for sig in "${@:2}"; do
      if [ "$sig" = EXIT ]; then has_exit=1; else other+=("$sig"); fi
    done
    if [ "$has_exit" = 1 ]; then
      case $1 in
      '' | -) reset_exit=1 ;;
      -*) ;;
      *) compose=1 ;;
      esac
    fi
  fi

  if [ "$compose" = 1 ]; then
    if [ "${CAP_EXIT_PID:-}" != "$BASHPID" ]; then
      CAP_EXIT_FNS=()
      CAP_EXIT_PID=$BASHPID
    fi
    CAP_EXIT_FNS+=("$1")
    builtin trap cap_run_exit_fns EXIT
    # shellcheck disable=SC2064 # forwarding whatever the caller passed, not building a trap string here
    [ "${#other[@]}" -eq 0 ] || builtin trap "$1" "${other[@]}"
  elif [ "$reset_exit" = 1 ]; then
    [ "${CAP_EXIT_PID:-}" != "$BASHPID" ] || CAP_EXIT_FNS=()
    # shellcheck disable=SC2064 # forwarding whatever the caller passed, not building a trap string here
    builtin trap "$@"
  else
    # shellcheck disable=SC2064 # forwarding whatever the caller passed, not building a trap string here
    builtin trap "$@"
  fi
}
cap_run_exit_fns() {
  # $? here is the real exit status that fired this trap - captured before
  # anything else touches it, then restored right before each eval so a
  # handler reading $? sees what it would in a plain `trap CMD EXIT`, not
  # this function's own BASHPID test. set +e for the same reason: `(exit
  # "$code")` failing on a nonzero code is not a real failure, but set -e,
  # inherited from the caller, would otherwise abort this loop on it.
  local fn code=$?
  [ "${CAP_EXIT_PID:-}" = "$BASHPID" ] || return 0
  set +e
  for fn in "${CAP_EXIT_FNS[@]}"; do
    (exit "$code")
    eval "$fn"
  done
  set -e
}

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
    CAP_LOCK_DEPTH[$slug]=$(( ${CAP_LOCK_DEPTH[$slug]:-1} + 1 ))
    return 0
  fi
  # Re-entrant: cap land can release via cap drop without deadlocking. The
  # marker is exported, so only the holder's children inherit it.
  case " ${CAP_LOCKS:-} " in *" $slug "*) return 0 ;; esac
  mkdir -p "$dir"
  local fd
  exec {fd}>>"$dir/.lock"
  flock -n "$fd" || { exec {fd}>&-; return 1; }
  printf 'pid %s (%s) since %s\n' "$$" "$(basename "$0")" "$(date -u +%H:%M:%SZ)" >"$dir/.lock"
  CAP_LOCKS="${CAP_LOCKS:-} $slug"
  export CAP_LOCKS
  CAP_LOCK_FDS[$slug]=$fd
  CAP_LOCK_DEPTH[$slug]=1

  # Pinned here, not inside session_identity: x=$(session_identity) always
  # runs in a subshell, so an export inside it never reaches the caller, and
  # cap-land shelling out to cap-drop needs the same identity under the same
  # harness. cap_env_scrub strips CAP_SESSION the same as CAP_LOCKS, so a
  # dispatched agent never sees it.
  if [ -z "${CAP_SESSION:-}" ]; then
    CAP_SESSION=$(session_identity)
    export CAP_SESSION
  fi

  # Flushes this task's queue the moment this process's hold on it ends,
  # never mid-review or mid-rebase. Registered once per process, so a
  # second slug locked here does not queue a second flush of the first.
  # A kill instead of a clean exit skips this trap; the flock still
  # releases at the kernel level, and the message waits for whichever
  # later holder locks this slug and exits cleanly.
  if [ -z "${CAP_LOCK_EXIT_ARMED:-}" ]; then
    CAP_LOCK_EXIT_ARMED=1
    trap task_flush_locks_on_exit EXIT
  fi
}

task_flush_locks_on_exit() {
  local slug
  for slug in ${CAP_LOCKS:-}; do queue_flush "$slug" || true; done
}

# Releases a lock task_try_lock took, as soon as a caller is done with the
# task - stack_sync_task's own failure paths, and its cascade callers once
# a descendant's per-child work is finished.
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
    CAP_LOCK_DEPTH[$slug]=$(( CAP_LOCK_DEPTH[$slug] - 1 ))
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
  [ -n "$owner" ] && agent_cwd_matches "$slug" "${owner%@*}" && return 0
  me=$(session_identity)
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

# One line per queued message: pid (possibly empty, see session_identity),
# a tab, then the text base64-encoded - not tr-flattened, so a multi-line
# message arrives exactly as typed whether the lock was free or not, and
# not raw, so a tab or newline inside the text itself can never be mistaken
# for the field separator or a second record. queue_flush splits each line
# on the first literal tab; base64's own alphabet contains neither.
queue_append() {
  local slug=$1 pid=$2 text=$3 fd
  exec {fd}>>"$TASKS/$slug/.send-queue.lock"
  flock "$fd"
  printf '%s\t%s\n' "$pid" "$(printf '%s' "$text" | base64 -w0)" \
    >>"$TASKS/$slug/send-queue"
  flock -u "$fd"
  exec {fd}>&-
}

# Durable queue for a cap-send delivery a busy task could not take. Guarded
# by its own lock, separate from the task lock, since this runs exactly
# when the caller could not get that lock.
queue_send() {
  local slug=$1 text=$2 id
  id=$(session_identity)
  queue_append "$slug" "${id%@*}" "$text"
}

# Ground truth for whether cap-send left a message queued for a task that
# has not gone in yet - a file's non-emptiness, not a word anyone chose.
# A holder killed mid-flush leaves the same backlog in send-queue.flushing
# instead, which queue_flush only folds back on its next call - until then
# it is exactly as pending as anything still in send-queue itself.
queue_pending() { [ -s "$TASKS/$1/send-queue" ] || [ -s "$TASKS/$1/send-queue.flushing" ]; }

# Prepends a file's lines onto a task's live spool, under queue_send's own
# lock, so nothing appended concurrently is lost or reordered behind
# content that was already there. On success the caller's file is spent
# and safe to remove; on failure (the swap itself could not be made) it
# returns 1 and leaves the file alone, so nothing is ever lost.
queue_prepend() {
  local slug=$1 f=$2 fd spool=$TASKS/$1/send-queue
  exec {fd}>>"$TASKS/$slug/.send-queue.lock"
  flock "$fd"
  { cat "$f" "$spool" 2>/dev/null || true; } >"$spool.recovering"
  if mv "$spool.recovering" "$spool" 2>/dev/null; then
    flock -u "$fd"
    exec {fd}>&-
    return 0
  fi
  rm -f "$spool.recovering"
  flock -u "$fd"
  exec {fd}>&-
  return 1
}

# Delivers what queue_send queued into a live pane, in order, then clears
# the queue - called explicitly by cap-send before its own message, and
# automatically from every locking command's EXIT trap on release. Returns
# 0 only once empty: a message typed but never confirmed is logged and
# dropped rather than requeued, since a later flush must never type it
# again; a non-zero return says the pane's state is not to be trusted.
queue_flush() {
  local slug=$1 dir=$TASKS/$1 fd claimed pid b64 text line
  local spool=$dir/send-queue
  claimed="$spool.flushing"

  # A holder killed mid-flush leaves its claim behind in *.flushing, which
  # nothing else ever reads back. Folding it in front of the live spool
  # before claiming again recovers it exactly like any other queued
  # message - only cap-send/task_try_lock ever call this for a given
  # slug's lock, so nothing else can be claiming the same file right now.
  if [ -f "$claimed" ]; then
    if queue_prepend "$slug" "$claimed"; then
      rm -f "$claimed"
    else
      # queue_prepend already left $claimed on disk for the next attempt.
      # Claiming $spool onto $claimed below would overwrite that undelivered
      # batch instead of recovering it - stop here and retry on the next flush.
      warn "$slug: could not recover queued messages in $claimed; left in place, will retry on the next flush"
      return 1
    fi
  fi

  [ -s "$spool" ] || return 0
  pane_live "$slug" || return 0

  exec {fd}>>"$dir/.send-queue.lock"
  flock "$fd"
  mv "$spool" "$claimed" 2>/dev/null || { flock -u "$fd"; exec {fd}>&-; return 0; }
  flock -u "$fd"
  exec {fd}>&-

  local n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ -n "$line" ] || continue
    pid=${line%%$'\t'*}
    b64=${line#*$'\t'}
    text=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
    if pane_submit "$slug" "$text"; then
      printf 'working: sent by %s: %s\n' "$(session_label "$pid")" "$(printf '%s' "$text" | tr '\n' ' ')" >>"$dir/status.log"
    else
      # pane_submit already typed this one in; a later flush retrying it
      # would type it again, which must never happen. Logged as unconfirmed
      # and dropped here instead of requeued. Anything after it in $claimed
      # was never typed at all, so it stays queued - prepended, not
      # appended, since anything already in $spool arrived after the claim
      # and so is newer than this.
      warn "$slug: a queued message from $(session_label "$pid") was typed but never confirmed; will not be retried - check by hand: cap peek $slug"
      printf 'unconfirmed: sent by %s: %s\n' "$(session_label "$pid")" "$(printf '%s' "$text" | tr '\n' ' ')" >>"$dir/status.log"
      tail -n "+$((n + 1))" "$claimed" >"$claimed.tail"
      if [ -s "$claimed.tail" ]; then
        if queue_prepend "$slug" "$claimed.tail"; then
          rm -f "$claimed" "$claimed.tail"
        else
          # $claimed still holds 1..n, already resolved (delivered or
          # dropped as unconfirmed) and logged. Left in place, the recovery
          # block above would fold the whole thing back next flush and
          # retype the unconfirmed one. Replace it with the tail alone.
          mv "$claimed.tail" "$claimed"
        fi
      else
        rm -f "$claimed" "$claimed.tail"
      fi
      return 1
    fi
  done <"$claimed"
  rm -f "$claimed"
}

task_children() {
  local s
  [ -n "${1:-}" ] || return 0
  for s in $(task_slugs); do
    [ "$(task_field "$s" CAP_PARENT)" = "$1" ] && printf '%s\n' "$s"
  done
  return 0
}

require_herdr() {
  { [ -n "${HERDR_ENV:-}" ] && have herdr; } && return
  die "herdr not detected: HERDR_ENV unset or herdr not on PATH"
}

# Create a Herdr tab and return its pane and tab IDs.
herdr_open() {
  local json pane tab
  json=$(herdr tab create --cwd "$1" --label "$2" --no-focus 2>/dev/null) || die "herdr tab create failed"
  pane=$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty')
  tab=$(printf '%s' "$json" | jq -r '.result.tab.tab_id // empty')
  [ -n "$pane" ] || die "herdr tab create returned no pane id"
  printf '%s %s' "$pane" "$tab"
}

task_pane() { awk -F= '$1=="CAP_PANE"{print $2}' "$TASKS/$1/task.env" 2>/dev/null; }

# Run a command in a pane via temp script. Typing directly overruns tty
# line-length limit with large prompts; "bash <script>" never does.
pane_launch() {
  local pane=$1 script
  shift
  script=$(mktemp)
  { printf '#!/usr/bin/env bash\n'; printf 'exec %s\n' "$(printf '%q ' "$@")"; } > "$script"
  herdr pane run "$pane" "bash $script" >/dev/null 2>&1 || die "herdr pane run failed"
}

# No agent session runs as a bare background child - it always runs in
# its own pane, opened and closed just for this call, never a shared
# watcher pane (rejected: with more than one caller dispatching at once,
# it shows whoever is newest, not the one being watched). Structured
# output is not traded away for that: stdout is teed to a file to parse
# and shown live too. Blocks until the command exits, then returns its rc.
pane_dispatch() {
  local tree=$1 label=$2 out=$3 err=$4
  shift 4
  if ! { [ -n "${HERDR_ENV:-}" ] && have herdr; }; then
    # No herdr to open a pane in: run directly, rather than losing ask,
    # gate, commit, cleanup and skills entirely in an environment that
    # never had herdr in the first place.
    (cd "$tree" && "$@" </dev/null >"$out" 2>"$err")
    return $?
  fi
  local pane script rc_file done_file waited=0
  local max=${CAP_ASK_MAX_WAIT:-3600}
  read -r pane _ <<<"$(herdr_open "$tree" "$label")"
  rc_file=$(mktemp)
  done_file=$(mktemp)
  rm -f "$done_file"
  script=$(mktemp)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -o pipefail\n'
    # No >/dev/null after tee: its own stdout is the script's stdout, which
    # is the pane. stderr goes straight to $err, unseen.
    printf '%s </dev/null 2>%q | tee %q\n' "$(printf '%q ' "$@")" "$err" "$out"
    printf 'echo $? >%q\n' "$rc_file"
    printf 'touch %q\n' "$done_file"
  } >"$script"
  herdr pane run "$pane" "bash $script" >/dev/null 2>&1 || die "herdr pane run failed"

  # Also gives up the moment the pane itself is gone (tab closed, herdr
  # restarted) instead of spinning out the full $max: the wrapper script
  # dies on SIGHUP without ever touching $done_file.
  local timed_out=0 pane_gone=0
  while [ ! -f "$done_file" ]; do
    if ! herdr pane get "$pane" >/dev/null 2>&1; then
      warn "$label: pane no longer exists; giving up rather than waiting out ${max}s"
      pane_gone=1
      break
    fi
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$max" ]; then
      warn "$label: still running after ${max}s; leaving its pane open rather than killing it blind"
      timed_out=1
      break
    fi
  done

  local rc=1
  if [ -f "$rc_file" ]; then
    rc=$(cat "$rc_file" 2>/dev/null || echo 1)
    case $rc in '' | *[!0-9]*) rc=1 ;; esac
  fi
  rm -f "$script"
  # A timed-out or pane-gone wrapper may still be running and still means
  # to write $rc_file and $done_file - removing them now only means it
  # recreates two orphaned files nothing will ever clean up. Left in place,
  # they sit next to a pane the warning above already said was left open.
  if [ "$timed_out" = 0 ] && [ "$pane_gone" = 0 ]; then
    rm -f "$rc_file" "$done_file"
    herdr pane close "$pane" >/dev/null 2>&1 || true
  fi
  return "$rc"
}

pane_live() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane get "$p" >/dev/null 2>&1
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
  pane_tail "$1" 8 | grep -oiE '(context|ctx) [0-9]+% used' | tail -1 | grep -oE '[0-9]+'
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
  local f=$TASKS/$1/status.log cursor start line bytes
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

  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    start=$((start + ${#line} + 1))
  done < <(tail -c +$((start + 1)) "$f")

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

# One helper answers "what state is this task in," so herdr - never a word
# an agent chose - decides whether it is working, git and gate.json decide
# what is ready, and the log is consulted only to name why it stopped. See
# docs/pipeline-notes.md, "Task state is not a log word".
task_state() {
  local slug=$1 agent age tree base verb

  if ! pane_live "$slug"; then
    agent=exited
  else
    agent=$(pane_agent_status "$slug")
    case $agent in
    working)
      printf working
      return
      ;;
    idle | done)
      # herdr's own account of "ready for input" - done and idle differ
      # only in whether a client has acknowledged it, not in whether the
      # agent is running (herdr --skill). Ground truth either way.
      agent=idle
      ;;
    blocked)
      # An approval/question prompt herdr itself recognised - ground truth
      # that this needs the captain now, not a log word to defer to.
      printf blocked
      return
      ;;
    *)
      # Genuinely ambiguous (unknown, or a harness herdr does not
      # instrument): falls back to whether the pane's visible output has
      # changed recently (task_state_stale_age).
      age=$(task_state_stale_age "$slug")
      if [ "$age" -ge "$CAP_IDLE_SECS" ]; then
        agent=idle
      else
        printf working
        return
      fi
      ;;
    esac

    # herdr has now settled *whether* it stopped; the log is read only for
    # *why*, and only for the three verbs that carry one - a bare "done" or
    # nothing logged at all is not a reason, so it falls through to ready
    # (git/gate.json) or the bare stopped state below. Only reached with the
    # pane still live: a dead pane's old log verb never gets to override
    # herdr's own account of the agent being gone.
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

git_dirty() { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }

# Sync a worktree onto the current tip of its base branch before review, so
# an unrelated task landing on base since this one branched never gets
# misread by a gate as this branch deleting/reverting that feature (see
# docs/pipeline-notes.md, "Stale-base false positives"). Safe by
# construction: proceeds only when both the merge and any stash reapply are
# conflict-free. On any conflict it leaves the worktree exactly as a human
# doing this by hand would (merge aborted, or mid-conflict with the original
# work recoverable from the stash) and reports rather than guessing.
# Returns 1 only when the worktree is left mid-conflict and should not be
# gated this round.
sync_base() {
  local tree=$1 base=$2 base_tip merge_base dirty stashed=0

  base_tip=$(git -C "$tree" rev-parse "$base" 2>/dev/null) || return 0
  merge_base=$(git -C "$tree" merge-base HEAD "$base" 2>/dev/null) || return 0
  [ "$base_tip" = "$merge_base" ] && return 0 # already current

  dirty=$(git_dirty "$tree")
  if [ "$dirty" != 0 ]; then
    git -C "$tree" stash push -u -m "cap-gate auto-sync" >/dev/null 2>&1 || {
      warn "$tree: could not stash before syncing onto $base; gating the stale diff as-is"
      return 0
    }
    stashed=1
  fi

  if ! git -C "$tree" merge "$base" --no-edit >/dev/null 2>&1; then
    git -C "$tree" merge --abort >/dev/null 2>&1
    [ "$stashed" = 1 ] && git -C "$tree" stash pop >/dev/null 2>&1
    warn "$tree: $base moved and merging it conflicts; gating the stale diff as-is (see docs/pipeline-notes.md)"
    return 0
  fi

  if [ "$stashed" = 1 ] && ! git -C "$tree" stash pop >/dev/null 2>&1; then
    warn "$tree: merged $base, but reapplying stashed work conflicts. The worktree is now mid-conflict; not gating this round. Resolve it (see docs/pipeline-notes.md), ideally by asking the task's own agent to run 'git stash pop' and fix the conflict itself."
    return 1
  fi

  printf 'cap: synced %s onto current %s before gating\n' "$tree" "$base" >&2
  return 0
}

# The commit to diff a worktree against: where its branch actually left base,
# not base's current tip. A sibling task landing into base after this branch
# was cut would otherwise show up as this branch's own change, in a diff, a
# fingerprint, or a reviewer's own `git diff` command. Used by cap-check,
# cap-cleanup, cap-gate, and gate_fingerprint below.
diff_base() {
  local tree=$1 base=$2 mb
  mb=$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null) || true
  printf '%s' "${mb:-$base}"
}

# Fingerprint of exactly what a gate reviews: full diff plus untracked files.
# Same fingerprint means identical code reviewed, independent of commits or
# stash round-trips. Untracked files must be included, since a diff alone
# says nothing about a new file the deliverable adds.
gate_fingerprint() {
  local tree=$1 base=$2 f
  base=$(diff_base "$tree" "$base")
  {
    git -C "$tree" diff "$base" 2>/dev/null || true
    # Hash each path as well as its bytes, so a rename is a new fingerprint.
    while IFS= read -r -d '' f; do
      printf '=== %s\n' "$f"
      cat -- "$tree/$f" 2>/dev/null || true
    done < <(git -C "$tree" ls-files --others --exclude-standard -z 2>/dev/null | sort -z)
  } | sha256sum | cut -d' ' -f1
}

# The markdown-decoration strip gate_report_lines finishes each surviving
# line with: list markers, heading/blockquote/bold/italic markers, trailing
# punctuation. Factored out so gate_has_evidence can test a raw line for
# being a verdict the same way gate_verdict does, instead of a stricter
# literal match that a decorated verdict line fails.
gate_strip_markdown() {
  sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]*//; s/^[[:space:]#>*_-]*//; s/[[:space:]#*_.]*$//'
}

# The cleaned line stream gate_verdict and gate_has_evidence both read, so
# the two never disagree about what a report says. Skips fenced code (```
# or ~~~, 3+, matched by character and length per CommonMark) and indented
# lines, then strips markdown structure - never quote marks or backticks.
gate_report_lines() {
  [ -f "$1" ] || return 0
  local body
  # grep -v exits 1, not just prints nothing, on a zero-byte report - what
  # cap-gate feeds this after a session-limit rejection. Harmless today only
  # because the caller uses a command substitution, where bash does not
  # apply set -e to the command inside.
  body=$(grep -v '^[[:space:]]*$' "$1" || true)
  printf '%s\n' "$body" |
    awk '
      # <=3 leading spaces then a run of ch (backtick or tilde). An opener
      # may carry an info string after the run (```sh); a closer may not -
      # only trailing spaces/tabs, checked by the caller when it matters.
      function fence_run(line, ch,    lead, rest, run) {
        lead = 0
        while (lead < 3 && substr(line, lead + 1, 1) == " ") lead++
        rest = substr(line, lead + 1)
        run = 0
        while (substr(rest, run + 1, 1) == ch) run++
        return run
      }
      function only_trailing_space(line, ch, run,    lead, rest, trail) {
        lead = 0
        while (lead < 3 && substr(line, lead + 1, 1) == " ") lead++
        rest = substr(line, lead + 1)
        trail = substr(rest, run + 1)
        gsub(/[ \t]/, "", trail)
        return trail == ""
      }
      {
        if (in_fence) {
          # A closer must be the same character, at least as long as the
          # opener, and bare - anything else, including the other fence
          # character or an info string, is still content.
          n = fence_run($0, fch)
          if (n >= flen && only_trailing_space($0, fch, n)) in_fence = 0
          next
        }
        n = fence_run($0, "`")
        if (n >= 3) { in_fence = 1; fch = "`"; flen = n; next }
        n = fence_run($0, "~")
        if (n >= 3) { in_fence = 1; fch = "~"; flen = n; next }
        if ($0 ~ /^(    |\t)/) next
        print
      }
    ' |
    gate_strip_markdown
}

# The exact-line GATE: PASS / GATE: FAIL verdict from a gate report. Last
# matching cleaned line wins.
gate_verdict() {
  gate_report_lines "$1" | grep -E '^GATE: (PASS|FAIL)$' | tail -1 |
    grep -oE 'PASS|FAIL' || printf 'UNKNOWN'
}

# Whether a report is more than the bare verdict gate_verdict just read off
# it. Reads raw, blank-filtered lines, not gate_report_lines' cleaned stream
# (rules/code.md wants failing output shown fenced or indented, which that
# stream strips), and tests each for being a verdict through
# gate_strip_markdown, the same normalisation gate_verdict itself reads through.
gate_has_evidence() {
  [ -f "$1" ] || return 1
  local lines total verdicts
  lines=$(grep -v '^[[:space:]]*$' "$1" || true)
  total=$(printf '%s\n' "$lines" | grep -c . || true)
  verdicts=$(printf '%s\n' "$lines" | gate_strip_markdown | grep -cE '^GATE: (PASS|FAIL)$' || true)
  [ "$total" -gt "$verdicts" ]
}

# Record one profile's verdict for a task at the fingerprint it reviewed.
# state/tasks/<slug>/gate.json holds the latest verdict per profile label
# (A, B), each tagged with the fingerprint it was reviewed at, so a reader
# can tell whether a PASS still describes the code currently in the tree.
gate_record() {
  local slug=$1 label=$2 verdict=$3 fp=$4
  local f=$TASKS/$slug/gate.json tmp prev
  prev=$([ -f "$f" ] && cat "$f" || echo '{}')
  tmp=$(mktemp)
  if jq -n --argjson prev "$prev" \
    --arg label "$label" --arg verdict "$verdict" --arg fp "$fp" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$prev + {($label): {verdict: $verdict, fingerprint: $fp, at: $at}}' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    warn "could not record gate verdict for $slug/$label"
  fi
}

# Whether a task is ready to land: both A and B last passed, and both did so
# reviewing the exact code currently in the tree (same fingerprint on both,
# matching the tree's fingerprint right now). Anything else - one profile
# never run, a FAIL, or a fingerprint mismatch from code changing since -
# means "not established as ready" and is reported as such, not guessed at.
gate_ready() {
  local slug=$1 tree=$2 base=$3
  local f=$TASKS/$slug/gate.json cur a_v a_fp b_v b_fp
  [ -f "$f" ] || return 1
  a_v=$(jq -r '.A.verdict // empty' "$f" 2>/dev/null || true)
  b_v=$(jq -r '.B.verdict // empty' "$f" 2>/dev/null || true)
  # Cheap file reads first: neither verdict can be PASS without both A and B
  # having run, so a task missing either is settled before gate_fingerprint's
  # git diff and untracked-file scan is worth paying for.
  [ "$a_v" = PASS ] && [ "$b_v" = PASS ] || return 1
  a_fp=$(jq -r '.A.fingerprint // empty' "$f" 2>/dev/null || true)
  b_fp=$(jq -r '.B.fingerprint // empty' "$f" 2>/dev/null || true)
  cur=$(gate_fingerprint "$tree" "$base")
  [ "$a_fp" = "$cur" ] && [ "$b_fp" = "$cur" ]
}

# rules/commits.md forbids crediting an AI, not a Co-Authored-By trailer as
# such - a cherry-picked upstream commit or a human pair credit is not this.
# Matches a session-link trailer, a generated-with byline, or a Co-Authored-By
# naming a known model or a vendor noreply address. One pattern, read by
# cap-commit (strips it) and cap-land (refuses on it), so the two never
# again disagree about what counts as AI attribution.
AI_TRAILER_RE='^(claude|codex)-session:|generated with \[(claude code|codex)\]|^co-authored-by:[[:space:]]*(claude|codex|chatgpt|gpt)\b|^co-authored-by:.*<noreply@(anthropic|openai)\.com>'

# Every AI-credited line in tree $1's $2..HEAD range, one per output line,
# prefixed with the short hash of the commit it is in. A plain
# `git log --format='commit %h:%n%B' | grep -in` cannot do this: grep prints
# only matching lines, so the marker line is dropped along with everything
# that did not match.
ai_trailer_report() {
  local tree=$1 base=$2 c hashes
  # A process substitution's own failure (an invalid range, git missing)
  # is invisible to the while loop that reads it - zero iterations reads
  # exactly like a clean range with nothing to flag. Read it into a
  # variable first so its exit status is this function's own.
  hashes=$(git -C "$tree" log --format=%h "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check attribution"
  [ -z "$hashes" ] && return 0
  while IFS= read -r c; do
    # grep exits 1 on the (usual) commit with nothing to flag; under set -e,
    # inherited from lib.sh, that would abort this loop at the first clean
    # commit instead of finishing the range.
    git -C "$tree" log -1 --format='%B' "$c" |
      { grep -inE "$AI_TRAILER_RE" || true; } | sed "s/^/$c: /"
  done <<<"$hashes"
}

git_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '-'; }
git_base() {
  local b
  b=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  [ -n "$b" ] || b=$(git_branch "$1")
  [ -n "$b" ] && [ "$b" != '-' ] || b=main
  printf '%s' "$b"
}

# Pre-accept the harness's trust dialog for a directory so a launch never stalls on it.
harness_trust() {
  local harness=$1 dir=$2 root cfg tmpj
  case $harness in
  claude)
    [ -f "$HOME/.claude.json" ] || return 0
    # Skip the read-modify-write when already trusted: every call used to
    # rewrite this shared file unconditionally, so N parallel gate/ask calls
    # raced on the same mv and one crashed with "File exists".
    jq -e --arg d "$dir" '.projects[$d].hasTrustDialogAccepted == true' \
      "$HOME/.claude.json" >/dev/null 2>&1 && return 0
    tmpj=$(mktemp)
    if jq --arg d "$dir" '.projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true})' \
         "$HOME/.claude.json" >"$tmpj" 2>/dev/null && [ -s "$tmpj" ]; then
      cp "$HOME/.claude.json" "$HOME/.claude.json.cap-bak" && mv "$tmpj" "$HOME/.claude.json"
    else
      rm -f "$tmpj"
      warn "could not trust $dir; the agent may stop on the trust dialog"
    fi
    ;;
  codex)
    # Codex resolves trust at the shared repo root, not per worktree.
    root=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
      root=$(dirname "$root") || root=$dir
    cfg=$HOME/.codex/config.toml
    if [ -f "$cfg" ] && ! grep -qF "[projects.\"$root\"]" "$cfg"; then
      cp "$cfg" "$cfg.cap-bak"
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$root" >>"$cfg"
    fi
    ;;
  esac
}

# Stacked tasks follow their parent's recorded branch tip.

STACK_MOVED=0
STACK_CONFLICT=""

# Store branch refs under state/restacks so --undo can restore them.
stack_snapshot_new() {
  mkdir -p "$CAP_HOME/state/restacks"
  printf '%s/state/restacks/%s-%s.snapshot' "$CAP_HOME" "$1" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# Save branch refs before rebase so --undo can restore them.
stack_snapshot_add() {
  git -C "$2" for-each-ref "refs/heads/$3" --format='%(objectname) %(refname)' >>"$1"
}

# Record a task.env field's current value before changing it, so --undo can
# put it back alongside the branch refs.
stack_snapshot_field() {
  printf 'FIELD %s %s %s\n' "$2" "$3" "$(task_field "$2" "$3")" >>"$1"
}

# Force-update a published branch after rebase.
stack_push() {
  git -C "$1" rev-parse --verify -q "origin/$2" >/dev/null || return 0
  git -C "$1" push --force-with-lease --force-if-includes origin "$2:$2" ||
    warn "could not push $2; its remote copy still holds the pre-rebase commits"
}

# Rebase a task from its recorded parent tip onto a new one.
# Run the rebase in the task worktree because Git rejects a branch checked out elsewhere.
# STACK_MOVED and STACK_CONFLICT report partial progress to the caller.
#
# Locks the child before touching it, and checks task_owner_free rather than
# claiming ownership: this rebases its worktree and rewrites its task record
# from inside a command the child never asked to run, so it must refuse a
# descendant with a live owner, but the cascading session is not that
# descendant's owner either, only a caller passing through under its lock.
stack_sync_task() {
  local task=$1 new_tip=$2 snap=$3
  local tree branch old_tip

  # Degrades the same way the rebase conflict below does, instead of
  # dying: a contended descendant must not take cap-land's or cap-restack's
  # whole run down with it, especially after cap-land has already merged
  # the parent PR by the time it reaches this call.
  if ! task_try_lock "$task"; then
    STACK_CONFLICT=$task
    warn "$task is locked by another cap command; its branch was left where it was"
    return 1
  fi

  if ! task_owner_free "$task"; then
    STACK_CONFLICT=$task
    warn "$task is owned by pid $(task_field "$task" CAP_OWNER 2>/dev/null | cut -d@ -f1); its branch was left where it was"
    task_unlock "$task"
    return 1
  fi

  tree=$(task_field "$task" CAP_TREE)
  branch=$(task_field "$task" CAP_BRANCH)
  old_tip=$(task_field "$task" CAP_PARENT_TIP)

  [ -d "$tree" ] || die "$task has no worktree at $tree"
  [ "$(git_dirty "$tree")" = 0 ] ||
    die "$task has uncommitted changes in $tree; commit or discard them first"

  if [ "$old_tip" != "$new_tip" ]; then
    stack_snapshot_add "$snap" "$tree" "$branch"

    if ! git -C "$tree" rebase --onto "$new_tip" "$old_tip"; then
      git -C "$tree" rebase --abort 2>/dev/null || true
      STACK_CONFLICT=$task
      warn "$task conflicts with its new base; its branch was left where it was"
      warn "resolve by hand: cd $tree && git rebase --onto $new_tip $old_tip"
      task_unlock "$task"
      return 1
    fi

    stack_push "$tree" "$branch"
    STACK_MOVED=$((STACK_MOVED + 1))
  fi

  stack_snapshot_field "$snap" "$task" CAP_PARENT_TIP
  task_env_set "$task" CAP_PARENT_TIP "$new_tip"
}

# The caller holds the child's lock across every field it rewrites, not
# just the rebase: stack_cascade_landed's CAP_BASE/CAP_PARENT/gh pr edit
# on this same child, right after stack_sync_task, is the same
# read-modify-write task_lock exists to serialize.
stack_cascade() {
  local slug=$1 new_tip=$2 snap=$3
  local child tree rc

  for child in $(task_children "$slug"); do
    tree=$(task_field "$child" CAP_TREE)

    stack_sync_task "$child" "$new_tip" "$snap" || return 1
    rc=0
    stack_cascade "$child" "$(git -C "$tree" rev-parse HEAD)" "$snap" || rc=$?

    # Flushed here, at the end of this child's own work, while its lock is
    # still held - not after task_unlock, which is queue_flush's own
    # invariant, and not deferred to the top-level caller, which would run
    # unlocked and race a concurrent cap-send over the same *.flushing file.
    queue_flush "$child" || true
    task_unlock "$child"
    [ "$rc" = 0 ] || return "$rc"
  done
}

# After a parent lands, descendants inherit its base and PR target.
stack_cascade_landed() {
  local slug=$1 new_tip=$2 snap=$3
  local child tree up_base up_parent pr rc

  up_base=$(task_field "$slug" CAP_BASE)
  up_parent=$(task_field "$slug" CAP_PARENT)

  for child in $(task_children "$slug"); do
    tree=$(task_field "$child" CAP_TREE)

    stack_sync_task "$child" "$new_tip" "$snap" || return 1

    stack_snapshot_field "$snap" "$child" CAP_BASE
    task_env_set "$child" CAP_BASE "$up_base"
    stack_snapshot_field "$snap" "$child" CAP_PARENT
    task_env_set "$child" CAP_PARENT "$up_parent"

    pr=$(task_field "$child" CAP_PR)
    if [ -n "$pr" ]; then
      gh pr edit "$pr" --base "$up_base" >/dev/null ||
        warn "could not retarget $pr to $up_base; set its base by hand"
    fi

    rc=0
    stack_cascade "$child" "$(git -C "$tree" rev-parse HEAD)" "$snap" || rc=$?

    # Flushed here, at the end of this child's own work, while its lock is
    # still held - see stack_cascade for why not after task_unlock and not
    # deferred to the top-level caller.
    queue_flush "$child" || true
    task_unlock "$child"
    [ "$rc" = 0 ] || return "$rc"
  done
}

# Every flag that strips an inherited model/session setting and CAP_*
# variable (CAP_LOCKS, CAP_SESSION, CAP_ASK_KEY, CAP_TASK, any future one)
# from a dispatched harness's environment - computed fresh from what is
# exported right now, not a maintained list, so a lock or identity pinned
# earlier in this process is always included.
cap_env_scrub() {
  local scrub=(-u ANTHROPIC_MODEL -u ANTHROPIC_SMALL_FAST_MODEL -u ANTHROPIC_DEFAULT_OPUS_MODEL
    -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u CLAUDE_CODE_SUBAGENT_MODEL
    -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CODEX_SANDBOX)
  local cap_var
  while IFS= read -r cap_var; do
    scrub+=(-u "$cap_var")
  done < <(compgen -e CAP_ || true)
  printf '%s\n' "${scrub[@]}"
}

# Point common package-manager caches at a shared location so a fresh
# worktree's install is not stuck starting cold, and a project's own relative
# cache config can't quietly defeat that sharing.
mkdir -p "$CAP_CACHE_ROOT"
CAP_CACHE_ENV=(
  NPM_CONFIG_CACHE="$CAP_CACHE_ROOT/npm"
  YARN_CACHE_FOLDER="$CAP_CACHE_ROOT/yarn"
  PIP_CACHE_DIR="$CAP_CACHE_ROOT/pip"
  CARGO_HOME="$CAP_CACHE_ROOT/cargo"
  GOMODCACHE="$CAP_CACHE_ROOT/go-mod"
  COMPOSER_CACHE_DIR="$CAP_CACHE_ROOT/composer"
)

ask_profile() {
  printf '%s\n' "$CAP_ASK_PROFILES" | awk -v p="$1" '$1==p {print $2, $3, ($4 == "" ? "-" : $4); found=1} END{exit !found}' ||
    die "unknown ask profile '$1' (see config/captain.conf)"
}

# --- dispatch sizing -------------------------------------------------------
#
# Captain never asks what plan the account is on. It reads the rate-limit
# windows the harness already reports to the status line, which bin/cap-statusline
# records for every session in the fleet, and it remembers which profiles the
# harness has actually rejected. Those two facts are enough to pick a model,
# and both are measurements rather than settings, so the same configuration
# behaves correctly on a plan Captain has never seen.

CAP_USAGE_DIR=$CAP_HOME/state/usage
CAP_BLOCK_DIR=$CAP_HOME/state/usage/blocked

usage_files() { compgen -G "$CAP_USAGE_DIR/*.json" >/dev/null 2>&1; }

# --- what the harness offers -----------------------------------------------
#
# Profile names a model and reasoning effort. Codex publishes both; Captain
# asks instead of guessing so invalid profiles fail early (cap models), not
# three minutes into a review. The catalog never carries tier assignments
# (which model is the right reviewer for critical work); that judgment stays
# in config/captain.conf.
#
# The claude harness publishes no equivalent, so its profiles go unchecked.
# Its aliases (opus, sonnet, haiku, fable) resolve at session start and the
# status line reports what they resolved to, which is discovery after the fact.

# One JSON-RPC round trip to the codex app-server. The server answers
# asynchronously and interleaves notifications, so this holds the request pipe
# open until the reply carrying the matching id arrives. Writing both requests
# and closing stdin does not work: the server sees EOF and exits before it has
# answered.
codex_rpc() {
  local method=$1 params=${2:-'{}'} d writer server rc=1 i
  command -v codex >/dev/null 2>&1 || return 1
  d=$(mktemp -d) || return 1
  if ! mkfifo "$d/in" 2>/dev/null; then
    rm -rf "$d"
    return 1
  fi
  {
    printf '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"captain","version":"1"}}}\n'
    printf '{"id":2,"method":"%s","params":%s}\n' "$method" "$params"
    # Become the sleep, so killing this pid closes the write end of the fifo.
    exec sleep 30
  } >"$d/in" 2>/dev/null &
  writer=$!
  timeout 30 codex app-server <"$d/in" >"$d/out" 2>/dev/null &
  server=$!
  for ((i = 0; i < 100; i++)); do
    if grep -q '"id":2' "$d/out" 2>/dev/null; then
      rc=0
      break
    fi
    if ! kill -0 "$server" 2>/dev/null; then break; fi
    sleep 0.05
  done
  kill "$writer" "$server" 2>/dev/null || true
  wait "$writer" "$server" 2>/dev/null || true
  if [ "$rc" = 0 ]; then grep -h '"id":2' "$d/out" | tail -1; fi
  rm -rf "$d"
  return "$rc"
}

# The result of one app-server method, cached on disk. Sizing is supposed to be
# free, so nothing here may cost a dispatch a network round trip it can avoid.
# A failure is cached too, as an empty file: a codex that is logged out or
# offline would otherwise charge every single dispatch a fresh timeout.
codex_cached() {
  local file=$1 ttl=$2 method=$3 params=${4:-'{}'} age out
  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 1
  file=$CAP_USAGE_DIR/$file
  if [ -f "$file" ]; then
    age=$(($(now) - $(stat -c %Y "$file" 2>/dev/null || echo 0)))
    if [ "$age" -lt "$ttl" ]; then
      [ -s "$file" ] || return 1
      cat "$file"
      return 0
    fi
  fi
  out=$(codex_rpc "$method" "$params" 2>/dev/null | jq -c '.result // empty' 2>/dev/null) || out=""
  if [ -z "$out" ] && [ -s "$file" ]; then
    # A catalog from yesterday is still the catalog. Keep it and stop asking
    # for one TTL rather than throwing away the only answer Captain has.
    touch "$file"
    cat "$file"
    return 0
  fi
  printf '%s' "$out" >"$file"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Every model this account can reach, as the harness reports it. Cached for a
# day: the list changes when OpenAI ships a model, not between dispatches.
codex_catalog() { codex_cached codex-models.json 86400 model/list '{"includeHidden":false}'; }

# Whether a profile names something the harness will accept. Prints what is
# wrong and returns 1 when it does not. Silent and successful when the profile
# is fine, when its harness publishes no catalog, and when the catalog cannot
# be read at all, because "Captain could not check" is not "the captain is
# wrong".
profile_check() {
  local profile=$1 harness model effort catalog problem
  read -r harness model effort <<<"$(ask_profile "$profile")"
  [ "$harness" = codex ] || return 0
  [ "$model" != '-' ] || return 0
  catalog=$(codex_catalog) || return 0
  problem=$(printf '%s' "$catalog" | jq -r --arg m "$model" --arg e "$effort" '
    (.data // []) as $all
    | ($all | map(select(.model == $m or .id == $m)) | first) as $found
    | if $found == null then
        "codex has no model \($m); it offers \($all | map(.model) | join(", "))"
      elif $e != "-" and (($found.supportedReasoningEfforts // []) | map(.reasoningEffort) | index($e)) == null then
        "\($m) does not accept effort \($e); it accepts \(($found.supportedReasoningEfforts // []) | map(.reasoningEffort) | join(", "))"
      else empty end
  ' 2>/dev/null) || return 0
  [ -n "$problem" ] || return 0
  printf '%s' "$problem"
  return 1
}

# The codex harness has no status line hook, so nothing records a reading for
# it as it runs. Two places have one anyway.
#
# The app-server answers account/rateLimits/read with the windows as they stand
# right now. That is the reading Captain wants, because the moment it most needs
# to know whether codex has room is the moment no codex session is running.
#
# Failing that, every turn appends a token_count event to the session's rollout,
# carrying the same two windows under snake_case names. It is a real reading but
# a retrospective one: it is exactly as old as the last codex turn.
#
# Both records also carry plan_type ("plus", "pro"). Captain does not read it.
# Knowing the percentage is measuring the account; knowing the plan is
# describing it, and a description is the thing that goes stale.
codex_rollout() {
  find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -newermt '-24 hours' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# Non-empty when codex last reported that a window is exhausted. This is the
# codex equivalent of the claude "hit your session limit" banner, and unlike
# that banner it is a field rather than a sentence, so it needs no matching.
codex_limit_reached() {
  codex_rate_limits | jq -r '.rate_limit_reached_type // empty' 2>/dev/null || true
}

codex_rollout_limits() {
  local f
  f=$(codex_rollout)
  [ -n "$f" ] || return 1
  grep -h '"rate_limits"' "$f" 2>/dev/null | tail -1 |
    jq -e '.payload.rate_limits // empty' 2>/dev/null
}

# The live reading when the app-server answers, the rollout when it does not.
# The two spell the same fields differently, so the live one is renamed into the
# rollout's shape and every caller below stays written once. The source travels
# with the reading so cap budget can say which one a number came from.
codex_rate_limits() {
  local live
  if live=$(codex_cached codex-limits.json "${CAP_USAGE_TTL:-900}" account/rateLimits/read); then
    if printf '%s' "$live" | jq -e '
      .rateLimits
      | {primary: (if .primary then {used_percent: .primary.usedPercent,
                                     resets_at: .primary.resetsAt,
                                     window_minutes: .primary.windowDurationMins} else null end),
         secondary: (if .secondary then {used_percent: .secondary.usedPercent,
                                         resets_at: .secondary.resetsAt,
                                         window_minutes: .secondary.windowDurationMins} else null end),
         rate_limit_reached_type: .rateLimitReachedType,
         source: "app-server"}
    ' 2>/dev/null; then
      return 0
    fi
  fi
  codex_rollout_limits | jq -e '. + {source: "rollout"}' 2>/dev/null
}

# Measured utilization for one harness, as "<percent> <resets_at> <source>". The
# percent is the fullest window that harness reports, because the tightest
# window is the one that will stop the next dispatch.
#
# Readings are per harness on purpose. An Anthropic window says nothing about
# an OpenAI one, and sizing a codex rung against a claude meter would be the
# same mistake as hardcoding a model: a number that describes a different
# account.
#
# Prints "- - none" when nothing recent enough exists, which every caller reads
# as "no reason to hold back", never as "full". Refusing to work because the
# meter is unreadable would be worse than the problem the meter solves.
usage_read() {
  local harness=${1:-claude} cutoff out
  cutoff=$(($(now) - ${CAP_USAGE_TTL:-900}))

  if usage_files; then
    # five_hour/seven_day come from the single newest record, same as always.
    # spend_limit comes from whichever record within the same cutoff last
    # actually observed one, independently - a headless call's record never
    # carries one, so it must not shadow an interactive session's still-fresh
    # reading just for being newer overall.
    out=$(jq -rs --argjson cutoff "$cutoff" --arg h "$harness" '
      map(select((.at // 0) >= $cutoff and (.harness // "claude") == $h)) as $recent
      | if ($recent | length) == 0 then empty else
          ($recent | max_by(.at)) as $latest
          | (now) as $n
          | ([$recent[] | select(.spend_limit != null)] | if length == 0 then null
             else (max_by(.at) | .spend_limit) end) as $sl
          | [(if ($latest.five_hour.resets_at // 0) > $n then ($latest.five_hour.pct // 0) else 0 end),
             (if ($latest.seven_day.resets_at // 0) > $n then ($latest.seven_day.pct // 0) else 0 end),
             (if $sl == null then 0 else
                (($sl.resets_at // 0) as $sr | if $sr == 0 or $sr > $n then ($sl.pct // 0) else 0 end)
              end)] as $p
          | "\($p | max | floor) \($latest.five_hour.resets_at // 0) snapshot"
        end
    ' "$CAP_USAGE_DIR"/*.json 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  if [ "$harness" = codex ]; then
    # A window whose reset time has passed is not still full, it is empty. This
    # matters here and not for claude, where a status line rewrites the reading
    # every few seconds; a rollout reading can easily outlive its own window.
    out=$(codex_rate_limits | jq -r '
      (now) as $n
      | (if (.primary.resets_at // 0) > $n then (.primary.used_percent // 0) else 0 end) as $p
      | (if (.secondary.resets_at // 0) > $n then (.secondary.used_percent // 0) else 0 end) as $s
      | "\([$p, $s] | max | floor) \(.primary.resets_at // 0) \(.source // "rollout")"
    ' 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  # The claude harness also caches a usage reading in ~/.claude.json, but only
  # refreshes it now and then, so it is a fallback and carries a longer life.
  if [ "$harness" = claude ] && [ -f "$HOME/.claude.json" ]; then
    out=$(jq -r --argjson cutoff "$(($(now) - 21600))" '
      .cachedUsageUtilization
      | select(((.fetchedAtMs // 0) / 1000) >= $cutoff)
      | .utilization.limits // []
      | if length == 0 then empty else "\(map(.percent) | max | floor) 0 cache" end
    ' "$HOME/.claude.json" 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  printf -- '- - none\n'
}

# A human breakdown of one harness's reading, for cap budget. Decisions use
# usage_read; this exists so a captain can see which window is the tight one.
usage_detail() {
  local harness=$1 src=$2
  case $harness:$src in
    claude:cache) printf 'from the harness cache in ~/.claude.json' ;;
    claude:*)
      usage_files || return 0
      jq -rs --arg h "$harness" '
        map(select((.harness // "claude") == $h))
        | if length == 0 then "" else
            (max_by(.at)
             | "5h \(.five_hour.pct // 0 | floor)%, 7d \(.seven_day.pct // 0 | floor)%, read \(now - .at | floor)s ago")
          end' "$CAP_USAGE_DIR"/*.json 2>/dev/null || true
      ;;
    codex:*)
      codex_rate_limits | jq -r '
        (if .source == "app-server" then "live from the codex app-server"
         else "from the newest codex rollout" end) as $src
        | "5h \(.primary.used_percent // 0 | floor)%, 7d \(.secondary.used_percent // 0 | floor)%, \($src)"
      ' 2>/dev/null || true
      ;;
  esac
}

# The rule for picking which of a result's modelUsage entries names the
# model actually asked for: the one whose canonicalModel/key names the
# profile's model, or the largest context window when nothing matches.
# usage_write and cap-ask's ctx_pct both interpolate this one definition, so
# a session with more than one model (a subagent adds its own entry) can
# never have the two disagree about which one is "the" model.
read -r -d '' CAP_MODEL_PICK_JQ <<'JQ' || true
def pick_model($model):
  (.modelUsage // {}) | to_entries as $entries
  | (if ($model // "") == "" or $model == "-" then null
     else ($entries | map(select((.value.canonicalModel // .key // "") | contains($model))) | .[0])
     end)
    // ($entries | max_by(.value.contextWindow // 0));
JQ

# Record a claude quota reading in the shape bin/cap-statusline writes in
# Python, so usage_read has a fresh number even for a session whose status
# line never rendered (that hook only fires for an interactive session).
# mise run check:usage-shape asserts the two writers agree on that shape.
usage_write() {
  local session=$1 dir=$2 rl_json=${3:-} result_json=${4:-} model=${5:-}
  [ -n "$session" ] || return 0

  # A rejection's own rate_limit_event doesn't always carry unifiedWindows
  # (its own rejection reason lives in api_error_status/terminal_reason
  # instead). Write nothing rather than let the // 0 defaults below publish
  # a fabricated 0% that usage_read's max_by(.at) would then prefer over any
  # real reading.
  jq -e '(.rate_limit_info.unifiedWindows.five_hour // .rate_limit_info.unifiedWindows.seven_day) != null' \
    <<<"${rl_json:-null}" >/dev/null 2>&1 || return 0

  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 0

  local model_id="" model_fallback="" display=""
  IFS=$'\t' read -r model_id model_fallback <<<"$(jq -r --arg model "$model" "$CAP_MODEL_PICK_JQ"'
    pick_model($model) as $mu | "\($mu.key // "")\t\($mu.value.canonicalModel // $mu.key // "")"
  ' <<<"${result_json:-null}" 2>/dev/null)" || true

  # Only an interactive status line learns a model's display name
  # (bin/cap-statusline, keyed by model.id); reuse its last recording for
  # this model id instead of restating the raw id. The "^claude-" exclusion
  # skips raw ids and this function's own past placeholder writes.
  if [ -n "$model_id" ]; then
    display=$(jq -rs --arg mid "$model_id" '
      map(select(.model_id == $mid and (.model // "") != "" and (((.model // "") | test("^claude-")) | not)))
      | sort_by(.at) | last | .model // empty
    ' "$CAP_USAGE_DIR"/*.json 2>/dev/null) || true
  fi

  # A headless call's rate_limit_event never carries a spend_limit field;
  # only bin/cap-statusline's interactive reading ever observes one. Write
  # null rather than carry an old reading forward under this call's own
  # fresh at - a carried value stopped aging out under CAP_USAGE_TTL, which
  # let a stale spend_limit outlive its own record indefinitely. usage_read
  # finds the newest record that actually observed one instead.
  jq -n --arg session "$session" --arg dir "$dir" --argjson at "$(now)" \
    --arg model_id "$model_id" --arg model_fallback "$model_fallback" \
    --argjson rl "${rl_json:-null}" --arg disp "$display" --argjson spend null '
    # Explicit half-away-from-zero, the formula bin/cap-statusline also uses
    # (math.floor(pct + 0.5)). mise run check:usage-shape asserts they agree.
    def pct_round: (. + 0.5) | floor;
    {at: $at, session_id: $session, harness: "claude",
     model_id: $model_id,
     model: (if $disp != "" then $disp else $model_fallback end),
     cwd: $dir, project_dir: $dir,
     five_hour: {pct: (($rl.rate_limit_info.unifiedWindows.five_hour.utilization // 0) * 100 | pct_round),
                 resets_at: ($rl.rate_limit_info.unifiedWindows.five_hour.resetsAt // 0)},
     seven_day: {pct: (($rl.rate_limit_info.unifiedWindows.seven_day.utilization // 0) * 100 | pct_round),
                 resets_at: ($rl.rate_limit_info.unifiedWindows.seven_day.resetsAt // 0)},
     spend_limit: $spend}' \
    >"$CAP_USAGE_DIR/$session.json.tmp" 2>/dev/null &&
    mv "$CAP_USAGE_DIR/$session.json.tmp" "$CAP_USAGE_DIR/$session.json"
}

# A profile the harness has rejected for a session limit is out of its tier
# until its window resets. This is the one signal that is never a guess: the
# account said no.
profile_block() {
  local p=$1 until=${2:-0}
  [ "$until" -gt "$(now)" ] 2>/dev/null || until=$(($(now) + ${CAP_BLOCK_SECS:-3600}))
  mkdir -p "$CAP_BLOCK_DIR"
  printf '%s\n' "$until" >"$CAP_BLOCK_DIR/$p"
}
profile_block_until() { cat "$CAP_BLOCK_DIR/$1" 2>/dev/null || printf '0'; }
profile_blocked() {
  local until
  until=$(profile_block_until "$1")
  if [ "$until" -gt "$(now)" ] 2>/dev/null; then
    return 0
  fi
  rm -f "$CAP_BLOCK_DIR/$1"
  return 1
}

# Sizing is a harness decision, so it reports to a file rather than to whoever
# is watching. A captain running cap spawn is an agent too: a line of routine
# "role crew -> sonnet" chatter on every dispatch spends its context to tell it
# something it did not ask for and cannot act on. cap budget reads this back
# when the answer needs explaining.
CAP_DISPATCH_LOG=$CAP_USAGE_DIR/dispatch.log

dispatch_log() {
  local caller=${0##*/}
  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$caller" "$1" "$2" "$3" "$4" >>"$CAP_DISPATCH_LOG" 2>/dev/null || return 0
  # Keep the tail, drop the history. Nobody audits a dispatch from last month.
  if [ "$(stat -c %s "$CAP_DISPATCH_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
    tail -n 200 "$CAP_DISPATCH_LOG" >"$CAP_DISPATCH_LOG.tmp" 2>/dev/null &&
      mv "$CAP_DISPATCH_LOG.tmp" "$CAP_DISPATCH_LOG"
  fi
}

# What kind of thinking a role needs, and which profiles can supply it.
role_tier() {
  local var
  var=CAP_ROLE_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-}"
}

tier_peers() {
  local var
  var=CAP_TIER_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-}"
}

tier_admit() {
  local var
  var=CAP_ADMIT_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-100}"
}

# Pick a profile from one tier. Peers within a tier are interchangeable in
# capability and live on different accounts, so a full window moves work
# sideways rather than downwards. Quota chooses which account runs the work and
# whether it starts at all; it never chooses how capable the agent is.
#
# `avoid` lets a caller that needs two independent opinions ask for a second.
tier_profile() {
  local tier=$1 role=$2 avoid=${3:-} peers profile admit pct pair harness
  peers=$(tier_peers "$tier")
  [ -n "$peers" ] || die "tier '$tier' lists no profiles (see config/captain.conf)"
  admit=$(tier_admit "$tier")

  for profile in $peers; do
    if [ "$profile" = "$avoid" ]; then
      continue
    fi
    if profile_blocked "$profile"; then
      continue
    fi
    # A peer naming a profile that does not exist is a typo in the config, not
    # a dispatch. Skipping it silently would size it against a harness of "",
    # which measures nothing and therefore holds nothing back.
    if ! pair=$(ask_profile "$profile" 2>/dev/null); then
      warn "tier '$tier' names unknown profile '$profile'; skipping it"
      continue
    fi
    read -r harness _ <<<"$pair"
    read -r pct _ _ <<<"$(usage_read "$harness")"
    if [ "$pct" != '-' ] && [ "$pct" -gt "$admit" ]; then
      continue
    fi
    dispatch_log "$role" "$profile" "$harness" "$pct"
    printf '%s' "$profile"
    return 0
  done
  return 1
}

role_profile() {
  local role=$1 tier
  tier=$(role_tier "$role")
  [ -n "$tier" ] || die "unknown dispatch role '$role' (see config/captain.conf)"
  tier_profile "$tier" "$role" "${2:-}"
}

role_profile_or_die() {
  local role=$1 tier=${2:-} p peers profile pair harness pct resets src until soonest=0 msg detail=""
  [ -n "$tier" ] || tier=$(role_tier "$role")
  [ -n "$tier" ] || die "unknown dispatch role '$role' (see config/captain.conf)"
  if p=$(tier_profile "$tier" "$role"); then
    printf '%s' "$p"
    return 0
  fi

  peers=$(tier_peers "$tier")
  for profile in $peers; do
    if profile_blocked "$profile"; then
      until=$(profile_block_until "$profile")
      detail="$detail $profile(rate limited until $(date -d "@$until" '+%H:%M'))"
      if [ "$soonest" = 0 ] || [ "$until" -lt "$soonest" ]; then
        soonest=$until
      fi
      continue
    fi
    pair=$(ask_profile "$profile" 2>/dev/null) || continue
    read -r harness _ <<<"$pair"
    read -r pct resets src <<<"$(usage_read "$harness")"
    detail="$detail $profile($harness at $pct%, source $src)"
    if [ "$resets" -gt "$(now)" ] 2>/dev/null; then
      if [ "$soonest" = 0 ] || [ "$resets" -lt "$soonest" ]; then
        soonest=$resets
      fi
    fi
  done

  # Say no rather than quietly running a smaller model. Work of this tier needs
  # a model of this tier; a cheaper one produces a session that has to be found
  # and undone, which costs more than the wait.
  msg="no $tier profile can take role '$role' right now:$detail"
  if [ "$soonest" -gt "$(now)" ] 2>/dev/null; then
    msg="$msg. Earliest capacity at $(date -d "@$soonest" '+%H:%M')"
  fi
  die "$msg. run: cap budget"
}
