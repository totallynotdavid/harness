# shellcheck shell=bash

# /proc/<pid>/stat counts fields after the process name from 1 (state).
# Split after the last ")" because the process name may contain spaces or ")".
proc_stat_field() {
  local pid=$1 n=$2 raw rest
  local -a fields

  raw=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  rest=${raw##*)}
  read -r -a fields <<<"$rest"

  printf '%s' "${fields[$((n - 1))]:-}"
}

CAP_EXIT_FNS=()

# Named handlers keep EXIT cleanup separate from command-local and signal traps.
cap_exit_add() {
  CAP_EXIT_FNS+=("$1")
  builtin trap cap_run_exit_fns EXIT
}

cap_run_exit_fns() {
  local fn code=$?

  set +e

  for fn in "${CAP_EXIT_FNS[@]}"; do
    (exit "$code")
    "$fn"
  done

  set -e
  return "$code"
}
