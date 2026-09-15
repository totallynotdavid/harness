# shellcheck shell=bash

die() {
  printf 'cap: %s\n' "$*" >&2
  exit 1
}

warn() { printf 'cap: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s; }
stamp() { date +%Y-%m-%d; }

proj_field() {
  [ -f "$PROJECTS" ] || die "no registry; run: cap map --sync"

  awk -F'\t' -v n="$1" -v c="$2" \
    '$1 == n { print $c; found = 1 } END { exit !found }' \
    "$PROJECTS" ||
    die "unknown project '$1' (cap map --sync to register)"
}

proj_path() { proj_field "$1" 2; }

proj_mode() {
  local mode
  mode=$(proj_field "$1" 3)
  printf '%s' "${mode:-pr}"
}

proj_model() { proj_field "$1" 4; }

task_dir() { printf '%s/%s' "$TASKS" "$1"; }

task_load() {
  local file="$TASKS/$1/task.env"
  [ -f "$file" ] || die "no such task '$1'"

  . "$file"
}

task_slugs() {
  [ -d "$TASKS" ] && ls -1 "$TASKS" 2>/dev/null || true
}

# Foreground commands have no pane for herdr to announce their result.
# Save it so the next captain prompt can report it.
cap_completion_write() {
  local file=$1
  local kind=$2
  local subject=$3
  local state=$4
  local rc=$5
  local started=$6
  local ended=${7:-}
  local tmp

  mkdir -p "$COMPLETIONS"
  tmp=$(mktemp "$COMPLETIONS/.completion.XXXXXX") || return 0

  if jq -n \
    --arg kind "$kind" \
    --arg subject "$subject" \
    --arg state "$state" \
    --argjson rc "$rc" \
    --arg started "$started" \
    --arg ended "$ended" \
    '{
      command: ("cap " + $kind + (if $subject == "" then "" else " " + $subject end)),
      state: $state,
      exit: $rc,
      started: $started,
      ended: $ended
    }' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

cap_completion_start() {
  [ -n "${CAP_COMPLETION_FILE:-}" ] && return 0

  local kind=$1
  local subject=${2:-}
  local id

  id="$$-$(date +%s%N)"

  CAP_COMPLETION_FILE="$COMPLETIONS/$id.json"
  CAP_COMPLETION_KIND=$kind
  CAP_COMPLETION_SUBJECT=$subject
  CAP_COMPLETION_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cap_completion_write \
    "$CAP_COMPLETION_FILE" \
    "$kind" \
    "$subject" \
    running \
    0 \
    "$CAP_COMPLETION_STARTED" \
    ""

  cap_exit_add cap_completion_finish
}

cap_completion_finish() {
  local rc=$?
  [ -n "${CAP_COMPLETION_FILE:-}" ] || return "$rc"

  cap_completion_write \
    "$CAP_COMPLETION_FILE" \
    "$CAP_COMPLETION_KIND" \
    "$CAP_COMPLETION_SUBJECT" \
    completed \
    "$rc" \
    "$CAP_COMPLETION_STARTED" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  return "$rc"
}

cap_completion_report() {
  local file
  local command
  local rc
  local state

  mkdir -p "$COMPLETIONS"
  find "$COMPLETIONS" -name '*.reported' -mtime +7 -delete 2>/dev/null || true

  for file in "$COMPLETIONS"/*.json; do
    [ -f "$file" ] || continue

    state=$(jq -r '.state // empty' "$file" 2>/dev/null || true)
    [ "$state" = completed ] || continue

    # Renaming claims the result so another captain session cannot report it.
    mv "$file" "$file.reported" 2>/dev/null || continue

    command=$(jq -r '.command // "cap command"' "$file.reported" 2>/dev/null || printf 'cap command')
    rc=$(jq -r '.exit // 1' "$file.reported" 2>/dev/null || printf 1)

    if [ "$rc" = 0 ]; then
      printf '  %s completed successfully\n' "$command"
    else
      printf '  %s finished with exit %s; inspect its output\n' "$command" "$rc"
    fi
  done
}
