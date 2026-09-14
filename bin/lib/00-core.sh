# This module is sourced by bin/lib.sh. Keep its public helpers stable.
# shellcheck shell=bash
# shellcheck disable=SC2034

die() {
  printf 'cap: %s\n' "$*" >&2
  exit 1
}
warn() { printf 'cap: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s; }
stamp() { date +%Y-%m-%d; }

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

# Foreground commands have no pane for herdr to announce when they finish.
# Keep their completion in Captain state so the reminder hook can surface it on
# the next captain prompt, including a non-zero result.
cap_completion_write() {
  local file=$1 kind=$2 subject=$3 state=$4 rc=$5 started=$6 ended=${7:-} tmp
  mkdir -p "$COMPLETIONS"
  tmp=$(mktemp "$COMPLETIONS/.completion.XXXXXX") || return 0
  if jq -n --arg kind "$kind" --arg subject "$subject" --arg state "$state" \
    --argjson rc "$rc" --arg started "$started" --arg ended "$ended" \
    '{command: ("cap " + $kind + (if $subject == "" then "" else " " + $subject end)), state: $state, exit: $rc, started: $started, ended: $ended}' \
    >"$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

cap_completion_start() {
  [ -n "${CAP_COMPLETION_FILE:-}" ] && return 0
  local kind=$1 subject=${2:-} id
  id="$$-$(date +%s%N)"
  CAP_COMPLETION_FILE=$COMPLETIONS/$id.json
  CAP_COMPLETION_KIND=$kind
  CAP_COMPLETION_SUBJECT=$subject
  CAP_COMPLETION_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cap_completion_write "$CAP_COMPLETION_FILE" "$kind" "$subject" running 0 "$CAP_COMPLETION_STARTED" ""
  cap_exit_add cap_completion_finish
}

cap_completion_finish() {
  local rc=$?
  [ -n "${CAP_COMPLETION_FILE:-}" ] || return "$rc"
  cap_completion_write "$CAP_COMPLETION_FILE" "$CAP_COMPLETION_KIND" "$CAP_COMPLETION_SUBJECT" \
    completed "$rc" "$CAP_COMPLETION_STARTED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  return "$rc"
}

# Atomically claim each completed command so two captain sessions do not both
# announce the same result. Reported files are retained briefly for diagnosis.
cap_completion_report() {
  local f command rc state
  mkdir -p "$COMPLETIONS"
  find "$COMPLETIONS" -name '*.reported' -mtime +7 -delete 2>/dev/null || true
  for f in "$COMPLETIONS"/*.json; do
    [ -f "$f" ] || continue
    state=$(jq -r '.state // empty' "$f" 2>/dev/null || true)
    [ "$state" = completed ] || continue
    mv "$f" "$f.reported" 2>/dev/null || continue
    command=$(jq -r '.command // "cap command"' "$f.reported" 2>/dev/null || printf 'cap command')
    rc=$(jq -r '.exit // 1' "$f.reported" 2>/dev/null || printf 1)
    if [ "$rc" = 0 ]; then
      printf '  %s completed successfully\n' "$command"
    else
      printf '  %s finished with exit %s; inspect its output\n' "$command" "$rc"
    fi
  done
}
