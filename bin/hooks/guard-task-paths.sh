#!/usr/bin/env bash
# Keep a task inside the paths it declared.
#
# The captain partitions the tree at dispatch. Nothing enforced the partition,
# so four agents each wrote package.json, vitest.config.ts, .env.example and
# the lockfile, and the merge had to be done by hand. A task that cannot reach
# the repository root cannot start that fight, which also means dependencies
# must be settled in the foundation before any fan-out.
#
# Silent for every write inside the task's own ground, and for anything outside
# the worktree entirely, such as the session scratchpad.
set -uo pipefail

. "$(dirname "$(readlink -f "$0")")/../lib.sh" 2>/dev/null || exit 0

slug=${1:-}
[ -n "$slug" ] || exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case $tool in
Edit | Write | NotebookEdit | MultiEdit) ;;
*) exit 0 ;;
esac

owns=$(owns_read "$slug" 2>/dev/null || true)
[ -n "$owns" ] || exit 0
tree=$(task_field "$slug" CAP_TREE 2>/dev/null || true)
[ -n "$tree" ] || exit 0

path=$(printf '%s' "$input" |
	jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -n "$path" ] || exit 0
case $path in
/*) ;;
*) path=$(printf '%s' "$input" | jq -r '.cwd // empty')/$path ;;
esac

# An agent must not be able to edit the declaration that constrains it.
# state/ holds every task's `owns`, and this hook used to wave through
# anything outside the worktree, so the first agent to hit a false block
# rewrote its own glob to widen it and carried on. A guard a subject can
# rewrite is not a guard. notes/ stays writable: a scout report lands there.
case $path in
"$CAP_HOME"/state/*)
	printf 'BLOCKED: %s cannot write to Captain state. %s constrains this task.\n' \
		"$slug" "${path#"$CAP_HOME"/}" >&2
	printf 'Need it changed? Say so in your report; the captain changes it.\n' >&2
	exit 2
	;;
esac

case $path in
"$tree"/*) rel=${path#"$tree"/} ;;
*) exit 0 ;;
esac

read -r -a globs <<<"$owns"
if owns_claims "$rel" "${globs[@]}"; then
	exit 0
fi

printf 'BLOCKED: %s owns %s and nothing else. %s belongs to another task.\n' \
	"$slug" "$owns" "$rel" >&2
printf 'Need it changed? Say so in your report; it becomes its own task.\n' >&2
exit 2
