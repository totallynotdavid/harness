#!/usr/bin/env bash
# Block dangerous git commands. Only checks the start of each command segment.
# Set CAP_ALLOW_DANGEROUS_GIT=1 to bypass this check.
set -u
[ -n "${CAP_ALLOW_DANGEROUS_GIT:-}" ] && exit 0

input=$(cat)

# Fail open when jq is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# Agents use isolated worktrees, so only block destructive local commands
# when Captain runs them directly.
patterns=()
if [ -z "${CAP_TASK:-}" ]; then
  patterns+=(
    '^git[[:space:]]+reset[[:space:]]+--hard'
    '^git[[:space:]]+-C[[:space:]]+[^[:space:]]+[[:space:]]+reset[[:space:]]+--hard'
    '^git[[:space:]]+clean[[:space:]]+-f'
    '^git[[:space:]]+branch[[:space:]]+-D'
    '^git[[:space:]]+checkout[[:space:]]+\.'
    '^git[[:space:]]+restore[[:space:]]+\.'
  )
fi

# Ignore heredoc bodies. A heredoc can hold text that looks like a dangerous
# command but is only being written out or piped as data, not run.
strip_heredocs() {
  local line delim='' in_heredoc=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_heredoc" = 1 ]; then
      [ "$line" = "$delim" ] && in_heredoc=0
      continue
    fi

    if [[ $line =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]? ]]; then
      delim=${BASH_REMATCH[1]}
      in_heredoc=1
    fi

    printf '%s\n' "$line"
  done
}

# A force-push rewrites a ref others may already have; a plain push only
# publishes a branch and is trivial to undo. Force-push is blocked in every
# process, agent or captain.
is_force_push() {
  local seg=$1 words i n
  read -ra words <<<"$seg"
  n=${#words[@]}

  [ "${words[0]:-}" = git ] || return 1
  i=1

  if [ "${words[$i]:-}" = -C ]; then
    i=$((i + 2))
  fi

  [ "${words[$i]:-}" = push ] || return 1
  i=$((i + 1))

  while [ "$i" -lt "$n" ]; do
    case "${words[$i]}" in
    --force | --force-with-lease | --force-with-lease=* | -f) return 0 ;;
    esac
    i=$((i + 1))
  done

  return 1
}

segments=$(printf '%s' "$cmd" | strip_heredocs | sed -E 's/(&&|\|\|)/\n/g' | tr ';|' '\n\n')

while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//')

  if is_force_push "$seg"; then
    printf 'BLOCKED: "%s" force-pushes. Ask the captain directly.\n' "$seg" >&2
    exit 2
  fi

  for p in "${patterns[@]}"; do
    if printf '%s' "$seg" | grep -qE "$p"; then
      printf 'BLOCKED: "%s" matches "%s". Ask the captain directly.\n' "$seg" "$p" >&2
      exit 2
    fi
  done
done <<<"$segments"

exit 0
