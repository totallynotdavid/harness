#!/usr/bin/env bash
# test-guard-self-dispatch - a dispatched agent running cap commit/cap deliver
# from inside its own worktree must be refused; only the orchestrating
# Captain session (running elsewhere) may commit or deliver a task.
set -euo pipefail

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

home=$scratch/home
fake_bin=$scratch/bin
mkdir -p "$home/config" "$home/state/tasks" "$fake_bin"
cp "$root/config/captain.conf" "$home/config/captain.conf"

# /proc/<pid>/comm comes from the executed file's own name, not a shebang
# script's name - so this must be a real binary named "claude".
cp "$(command -v bash)" "$fake_bin/claude"

tree=$scratch/tree
git init -q -b main "$tree"
git -C "$tree" config user.name test
git -C "$tree" config user.email test@example.test
printf 'base\n' >"$tree/file"
git -C "$tree" add file
git -C "$tree" commit -qm base
git -C "$tree" checkout -qb cap/t1
printf 'change\n' >>"$tree/file"
git -C "$tree" add file
git -C "$tree" commit -q -m 'add a change' -m 'Why: fixture for the self-dispatch guard.'

slug=t1
mkdir -p "$home/state/tasks/$slug"
cat >"$home/state/tasks/$slug/task.env" <<EOF
CAP_SLUG=$slug
CAP_TREE=$tree
CAP_BASE=main
CAP_PROJECT=demo
CAP_KIND=task
EOF

# Run from inside the task's own tree, under the fake "claude" ancestor:
# this must be refused for both cap commit and cap deliver.
for script in cap-commit cap-deliver; do
	if CAP_HOME="$home" PATH="$fake_bin:$PATH" "$fake_bin/claude" -c \
		'cd "$1" || exit 1; shift; ( "$@" )' claude "$tree" "$root/bin/$script" "$slug" \
		>"$scratch/out.log" 2>&1; then
		echo "test-guard-self-dispatch: '$script $slug' should have been refused from inside the task's own worktree" >&2
		cat "$scratch/out.log" >&2
		exit 1
	fi
	grep -q "own agent cannot run" "$scratch/out.log"
done

# The orchestrating Captain session (no claude/codex ancestor with a
# matching cwd - this test script itself, running from $root) is unaffected.
out=$(CAP_HOME="$home" "$root/bin/cap-commit" "$slug")
echo "$out" | grep -q 'already committed; nothing new to commit'

echo "test-guard-self-dispatch: ok"
