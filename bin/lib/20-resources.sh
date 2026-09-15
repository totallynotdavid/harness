# shellcheck shell=bash

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

project_lock() {
  local project=$1 dir fd

  dir=$VERIFIED/$project
  mkdir -p "$dir"

  # Verification runs in the shared checkout, so concurrent runs would
  # modify the same tree.
  exec {fd}>>"$dir/.lock"
  flock -n "$fd" ||
    die "$project is already being verified by $(cat "$dir/.lock" 2>/dev/null || echo 'another cap verify --repo')"

  printf 'pid %s (%s) since %s\n' \
    "$$" "$(basename "$0")" "$(date -u +%H:%M:%SZ)" >"$dir/.lock"
}

PEAKS=$CAP_HOME/state/peaks

project_peak_mb() {
  local file=$PEAKS/$1
  local value=""

  if [ -f "$file" ]; then
    value=$(cat "$file" 2>/dev/null || true)
  fi

  case $value in
  '' | *[!0-9]*)
    printf '%s' "${CAP_MIN_FREE_MB:-1200}"
    ;;
  *)
    printf '%s' "$value"
    ;;
  esac
}

project_peak_record() {
  local project=$1 mb=$2
  local current=0
  local next

  case $mb in
  '' | *[!0-9]*)
    return 0
    ;;
  esac

  mkdir -p "$PEAKS"

  current=$(cat "$PEAKS/$project" 2>/dev/null || echo 0)
  case $current in
  '' | *[!0-9]*)
    current=0
    ;;
  esac

  if [ "$current" -eq 0 ]; then
    printf '%s\n' "$mb" >"$PEAKS/$project"
    return 0
  fi

  # Decay old peaks, but never record less than the latest measurement.
  next=$(((current * 3 + mb + 3) / 4))
  if [ "$next" -lt "$mb" ]; then
    next=$mb
  fi

  printf '%s\n' "$next" >"$PEAKS/$project"
}

project_slots() {
  local project=$1
  local available
  local peak

  available=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  peak=$(project_peak_mb "$project")

  if [ "$peak" -le 0 ]; then
    peak=1200
  fi

  printf '%s' "$((available / peak))"
}

batch_project() {
  sed -n 's/^#[[:space:]]*project:[[:space:]]*//p' "$1" 2>/dev/null | head -1
}
