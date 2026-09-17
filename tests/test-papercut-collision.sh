#!/usr/bin/env bash
# test-papercut-collision - a union merge can leave two entries sharing one
# id (each side's `add` picked the next id independently). close must
# remove exactly one and say the id is still ambiguous, never both or none.
set -euo pipefail

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

home=$scratch/home
mkdir -p "$home/config"
: >"$home/config/projects.tsv"

cat >"$home/paper-cuts.jsonl" <<'EOF'
{"id": 1, "opened": "2026-08-30", "subject": "unsorted", "status": "open", "text": "one"}
{"id": 3, "opened": "2026-09-17", "subject": "commit", "status": "open", "text": "main branch entry"}
{"id": 3, "opened": "2026-09-17", "subject": "sessions", "status": "open", "text": "side branch entry"}
EOF

run() { CAP_HOME="$home" python3 "$root/bin/cap-papercut" "$@"; }

out=$(run close 3)
echo "$out" | grep -q '1 more entry still use #3'
[ "$(wc -l <"$home/paper-cuts.jsonl")" = 2 ]
grep -q 'side branch entry' "$home/paper-cuts.jsonl"
grep -q '"id": 1' "$home/paper-cuts.jsonl"

out=$(run close 3)
echo "$out" | grep -qx 'removed #3'
[ "$(wc -l <"$home/paper-cuts.jsonl")" = 1 ]
grep -q '"id": 1' "$home/paper-cuts.jsonl"

echo "test-papercut-collision: ok"
