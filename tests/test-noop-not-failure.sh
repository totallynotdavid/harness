#!/usr/bin/env bash
# test-noop-not-failure - a second cap commit/gate/cleanup run against a task
# already satisfied (no reviewable diff left) must report success, not a
# scary-looking failure indistinguishable from a real error.
set -euo pipefail

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

home=$scratch/home
mkdir -p "$home/config" "$home/state/tasks"
cp "$root/config/captain.conf" "$home/config/captain.conf"

new_tree() {
	local tree=$1
	git init -q -b main "$tree"
	git -C "$tree" config user.name test
	git -C "$tree" config user.email test@example.test
	printf 'base\n' >"$tree/file"
	git -C "$tree" add file
	git -C "$tree" commit -qm base
	git -C "$tree" checkout -qb "cap/$(basename "$tree")"
}

write_task() {
	local slug=$1 tree=$2
	mkdir -p "$home/state/tasks/$slug"
	cat >"$home/state/tasks/$slug/task.env" <<EOF
CAP_SLUG=$slug
CAP_TREE=$tree
CAP_BASE=main
CAP_PROJECT=demo
CAP_KIND=task
EOF
}

run() {
	CAP_HOME="$home" "$root/bin/$1" "${@:2}"
}

# cap-commit: a clean worktree with commits already ahead of base (as if a
# prior, successful cap commit already ran) must be a success, not a die.
already_committed=$scratch/already-committed
new_tree "$already_committed"
printf 'change\n' >>"$already_committed/file"
git -C "$already_committed" add file
git -C "$already_committed" commit -q -m 'add a change' -m 'Why: fixture already has a real commit.'
write_task already-committed "$already_committed"

out=$(run cap-commit already-committed)
echo "$out" | grep -q 'already committed; nothing new to commit'

# cap-commit: a clean worktree with NO commits ahead of base is still a real
# error - nothing to distinguish it from a caller mistake.
never_committed=$scratch/never-committed
new_tree "$never_committed"
write_task never-committed "$never_committed"

if run cap-commit never-committed >"$scratch/out.log" 2>&1; then
	echo "test-noop-not-failure: cap-commit should have failed on a genuinely empty task" >&2
	cat "$scratch/out.log" >&2
	exit 1
fi
grep -q "nothing to commit" "$scratch/out.log"

# cap-gate: no reviewable diff against base must be a success, not a die.
gated=$scratch/gated
new_tree "$gated"
write_task gated "$gated"

out=$(run cap-gate gated)
echo "$out" | grep -q 'already in the base'

# cap-cleanup: no diff against base must be a success, not a die.
cleaned=$scratch/cleaned
new_tree "$cleaned"
write_task cleaned "$cleaned"

out=$(run cap-cleanup cleaned)
echo "$out" | grep -q 'nothing to clean up'

echo "test-noop-not-failure: ok"
