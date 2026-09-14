# shellcheck shell=bash

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

# Keep a decaying maximum. A high reading still protects the next wave, while
# repeated lower readings bring the estimate back toward what the project now
# costs instead of preserving one unlucky build forever.
project_peak_record() {
  local project=$1 mb=$2 cur=0 next
  case $mb in '' | *[!0-9]*) return 0 ;; esac
  mkdir -p "$PEAKS"
  cur=$(cat "$PEAKS/$project" 2>/dev/null || echo 0)
  case $cur in '' | *[!0-9]*) cur=0 ;; esac
  [ "$cur" -gt 0 ] || {
    printf '%s\n' "$mb" >"$PEAKS/$project"
    return 0
  }
  next=$(((cur * 3 + mb + 3) / 4))
  [ "$next" -ge "$mb" ] || next=$mb
  printf '%s\n' "$next" >"$PEAKS/$project"
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
