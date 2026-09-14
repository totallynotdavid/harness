#!/usr/bin/env bash
# Prove the source scanners reject the shell shapes they claim to prevent.
set -euo pipefail

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cp -a "$root/bin" "$scratch/"
mkdir -p "$scratch/tests"
cp -a "$root/tests/static" "$scratch/tests/"

expect_rejected() {
  local name=$1 checker=$2
  if "$scratch/tests/static/$checker" >/dev/null 2>&1; then
    printf 'test-static-contracts: %s accepted its bad fixture\n' "$name" >&2
    exit 1
  fi
}

cat >"$scratch/bin/cap-mutant" <<'EOF'
#!/usr/bin/env bash
bad() {
  [ -n x ] && return 1
}
bad
EOF
expect_rejected and-list lint-andlist

cat >"$scratch/bin/cap-mutant" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line; do
  printf '%s\n' "$line"
done < <(false)
EOF
expect_rejected process-substitution lint-procsub

cat >"$scratch/bin/cap-mutant" <<'EOF'
#!/usr/bin/env bash
git rev-list --reverse HEAD
EOF
expect_rejected rev-list-order lint-revlist-topo

cat >"$scratch/bin/cap-mutant" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case $1 in
  --unused) unused=1; shift ;;
  *) shift ;;
  esac
done
EOF
expect_rejected dead-flag lint-dead-flag

printf '# previously broken\n' >>"$scratch/bin/cap"
expect_rejected comment-policy lint-comments

sed -i 's/task_state "\$slug"/true/' "$scratch/bin/cap-crew"
expect_rejected task-state lint-task-state

printf 'test-static-contracts: source scanners reject their known bad shapes\n'
