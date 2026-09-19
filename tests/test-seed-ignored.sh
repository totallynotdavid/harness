#!/usr/bin/env bash
# test-seed-ignored - exercise seeding a project's untracked contract files into a worktree.
set -euo pipefail

bin=$(cd "$(dirname "$(readlink -f "$0")")/../bin" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home/config"
: >"$scratch/home/config/captain.conf"

repo=$scratch/repo
tree=$scratch/tree
git init -q "$repo"
git -C "$repo" config user.email cap@example.invalid
git -C "$repo" config user.name cap

printf '.env\n' >"$repo/.gitignore"
printf 'tracked\n' >"$repo/README.md"
printf 'committed contract\n' >"$repo/CLAUDE.md"
git -C "$repo" add .gitignore README.md CLAUDE.md
git -C "$repo" -c commit.gpgsign=false commit -qm init

printf 'CLAUDE.local.md\n' >>"$repo/.git/info/exclude"
printf 'SECRET=1\n' >"$repo/.env"
printf 'ignored contract\n' >"$repo/CLAUDE.local.md"
printf 'loose contract\n' >"$repo/AGENTS.md"
printf 'uncommitted edit\n' >"$repo/CLAUDE.md"

git -C "$repo" worktree add -q "$tree" -b seed-test

err=$(CAP_HOME="$scratch/home" bash -c '
  . "$0"
  seed_ignored_files "$1" "$2" .env CLAUDE.local.md AGENTS.md CLAUDE.md
' "$bin/lib.sh" "$repo" "$tree" 2>&1 >/dev/null)

[ "$(cat "$tree/.env")" = "SECRET=1" ] || {
  printf 'test-seed-ignored: a .gitignored .env was not seeded\n' >&2
  exit 1
}

[ "$(cat "$tree/CLAUDE.local.md")" = "ignored contract" ] || {
  printf 'test-seed-ignored: a file excluded through .git/info/exclude was not seeded\n' >&2
  exit 1
}

# An unignored copy would be staged by cap commit's `git add -A`.
[ ! -e "$tree/AGENTS.md" ] || {
  printf 'test-seed-ignored: an untracked but unignored AGENTS.md was seeded anyway\n' >&2
  exit 1
}

case $err in
*AGENTS.md*not\ ignored*) ;;
*)
  printf 'test-seed-ignored: the skipped AGENTS.md was not reported: %s\n' "$err" >&2
  exit 1
  ;;
esac

[ "$(cat "$tree/CLAUDE.md")" = "committed contract" ] || {
  printf 'test-seed-ignored: a tracked CLAUDE.md was overwritten by the main checkout\n' >&2
  exit 1
}

[ -z "$(git -C "$tree" status --porcelain)" ] || {
  printf 'test-seed-ignored: seeding left the worktree dirty:\n%s\n' \
    "$(git -C "$tree" status --porcelain)" >&2
  exit 1
}

printf 'test-seed-ignored: ignored contracts and secrets reach the worktree, loose ones are reported\n'
