#!/usr/bin/env bash
# Pull this checkout forward at session start, but only when it costs
# nothing to be wrong about: a clean tree and a plain fast-forward. Every
# host runs an independent clone with no other sync, so a session that
# starts on stale code can rediscover a bug another host already fixed.
#
# Anything this can't do safely (a dirty tree, a real divergence) is left
# for task-status.sh's ahead/behind line, which runs on every prompt and
# already tells the operator to resolve it by hand.
set -uo pipefail
cat >/dev/null

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 0
cd "$repo" || exit 0
[ -d .git ] || exit 0

git fetch -q origin 2>/dev/null || exit 0

branch=$(git symbolic-ref --short -q HEAD 2>/dev/null) || exit 0
git rev-parse -q --verify "origin/$branch" >/dev/null 2>&1 || exit 0

[ -z "$(git status --porcelain 2>/dev/null)" ] || exit 0

# Refuse anything but a fast-forward: never merge, never rebase, never touch
# a local commit this checkout hasn't pushed yet.
git merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null || exit 0

before=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
git merge -q --ff-only "origin/$branch" >/dev/null 2>&1 || exit 0
after=$(git rev-parse --short HEAD 2>/dev/null) || exit 0

if [ "$before" != "$after" ]; then
  printf 'captain: fast-forwarded %s from %s to %s (origin/%s)\n' \
    "$(basename "$repo")" "$before" "$after" "$branch"
fi

exit 0
