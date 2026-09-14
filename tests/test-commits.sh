#!/usr/bin/env bash
# test-commits - exercise the shared commit message rules.
set -euo pipefail

bin=$(cd "$(dirname "$(readlink -f "$0")")/../bin" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home/config"
: >"$scratch/home/config/captain.conf"

tree=$scratch/tree
git init -q -b main "$tree"
git -C "$tree" config user.name lint
git -C "$tree" config user.email lint@example.test
printf 'base\n' >"$tree/file"
git -C "$tree" add file
git -C "$tree" commit -qm base
git -C "$tree" checkout -qb cap/t

printf 'good\n' >>"$tree/file"
git -C "$tree" add file
git -C "$tree" commit -q -m 'add a useful change' -m 'Why: Keep the fixture focused on message rules.'

good=$(CAP_HOME="$scratch/home" bash -c '. "$0"; commit_rule_report "$1" main' "$bin/lib.sh" "$tree")
[ -z "$good" ] || {
  printf 'test-commits: valid message was rejected:\n%s\n' "$good" >&2
  exit 1
}

printf 'bad\n' >>"$tree/file"
git -C "$tree" add file
git -C "$tree" commit -q -m 'fix: this summary is deliberately far too long for the rule.' -m 'This body restates the changed file.'
bad=$(CAP_HOME="$scratch/home" bash -c '. "$0"; commit_rule_report "$1" main' "$bin/lib.sh" "$tree")
grep -q 'summary is .* characters' <<<"$bad"
grep -q 'conventional-commit prefix' <<<"$bad"
grep -q 'summary ends with a period' <<<"$bad"
grep -q 'body must begin with Why:' <<<"$bad"

printf 'upper\n' >>"$tree/file"
git -C "$tree" add file
git -C "$tree" commit -q -m 'Add an uppercase summary' -m 'Why: Exercise the lowercase subject rule.'
upper=$(CAP_HOME="$scratch/home" bash -c '. "$0"; commit_rule_report "$1" main' "$bin/lib.sh" "$tree")
grep -q 'summary must start with a lowercase word' <<<"$upper"

planned=$scratch/planned
git init -q -b main "$planned"
git -C "$planned" config user.name lint
git -C "$planned" config user.email lint@example.test
printf 'base\n' >"$planned/README.md"
git -C "$planned" add README.md
git -C "$planned" commit -qm base
git -C "$planned" checkout -qb cap/t
printf 'services:\n  app:\n    image: example/app\n' >"$planned/compose.yaml"
printf 'base\n\nRun the application with compose.\n' >"$planned/README.md"
git -C "$planned" add README.md compose.yaml
git -C "$planned" commit -q -m 'add compose setup' -m 'Why: Keep runtime setup and its usage instructions together.'

plan=$scratch/commit-plan.json
cat >"$plan" <<'EOF'
{"commits":[{"summary":"add compose setup","why":"Keep runtime setup and its usage instructions together.","paths":["README.md","compose.yaml"]}]}
EOF
good_plan=$(CAP_HOME="$scratch/home" bash -c '. "$0"; commit_plan_report "$1" main "$2"' "$bin/lib.sh" "$planned" "$plan")
[ -z "$good_plan" ] || {
  printf 'test-commits: valid commit plan was rejected:\n%s\n' "$good_plan" >&2
  exit 1
}

cat >"$plan" <<'EOF'
{"commits":[{"summary":"Add compose setup","why":"Keep runtime setup and its usage instructions together.","paths":["README.md","compose.yaml"]}]}
EOF
bad_plan=$(CAP_HOME="$scratch/home" bash -c '. "$0"; commit_plan_report "$1" main "$2"' "$bin/lib.sh" "$planned" "$plan")
grep -q 'summary must start with a lowercase word' <<<"$bad_plan"

cat >"$plan" <<'EOF'
{"commits":[{"summary":"add compose file","why":"Keep runtime setup together.","paths":["compose.yaml"]},{"summary":"document compose setup","why":"Keep usage instructions together.","paths":["README.md"]}]}
EOF
bad_plan=$(CAP_HOME="$scratch/home" bash -c '. "$0"; commit_plan_report "$1" main "$2"' "$bin/lib.sh" "$planned" "$plan")
grep -q 'group(s)' <<<"$bad_plan"

printf 'test-commits: cap commit and cap land share message checks\n'
