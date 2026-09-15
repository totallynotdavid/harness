#!/usr/bin/env bash
# Keep this session from writing directly to project repositories.
# Set CAP_ALLOW_PROJECT_WRITE=1 to allow writes anywhere.
set -u
[ -n "${CAP_ALLOW_PROJECT_WRITE:-}" ] && exit 0

input=$(cat)

# Fail open when jq is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case "$tool" in
Edit | Write) path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty') ;;
NotebookEdit) path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty') ;;
*) exit 0 ;;
esac
[ -n "$path" ] || exit 0

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=config/captain.conf
. "$repo/config/captain.conf"

work_root=$(cd "$CAP_WORK_ROOT" 2>/dev/null && pwd) || work_root=$CAP_WORK_ROOT

case "$path" in
/*) abs=$path ;;
*) abs="$PWD/$path" ;;
esac

dir=$(cd "$(dirname "$abs")" 2>/dev/null && pwd) || dir=$(dirname "$abs")
resolved="$dir/$(basename "$abs")"

# The captain's own memory store is harness state, not project source. This
# guard exists to stop source being hand-edited outside an agent worktree, and
# blocking the memory directory only stopped the memory system from working.
case "$resolved" in
"$HOME"/.claude/projects/*/memory/*) exit 0 ;;
esac

case "$resolved" in
"$repo"/paper-cuts.md | "$repo"/paper-cuts.jsonl)
  printf 'BLOCKED: %s is the paper-cut ledger. Use cap papercut add <subject> "<text>" or cap papercut close <id>.\n' "$path" >&2
  exit 2
  ;;
"$repo"/*) exit 0 ;;
"$work_root"/*)
  printf 'BLOCKED: %s cannot write to %s. This file belongs to an agent. Use cap send, cap deliver, or cap drop instead. Set CAP_ALLOW_PROJECT_WRITE=1 to override.\n' "$tool" "$path" >&2
  exit 2
  ;;
esac

printf 'BLOCKED: %s cannot write to %s. Files outside this repository must be changed by an agent. Use cap spawn <slug> <project>. Set CAP_ALLOW_PROJECT_WRITE=1 to override.\n' "$tool" "$path" >&2
exit 2
