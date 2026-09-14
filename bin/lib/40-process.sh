# This module is sourced by bin/lib.sh. Keep its public helpers stable.
# shellcheck shell=bash
# shellcheck disable=SC2034

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

# Register named EXIT handlers explicitly. Keeping this separate from Bash's
# trap builtin makes signal traps and command-local cleanup predictable.
CAP_EXIT_FNS=()

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
