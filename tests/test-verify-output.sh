#!/usr/bin/env bash
# test-verify-output - prove detached check children cannot hold a caller pipe.
set -euo pipefail

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
scratch=$(mktemp -d)
trap 'kill "$(cat "$scratch/fake.pid" 2>/dev/null)" 2>/dev/null || true' EXIT

mkdir -p "$scratch/home/config" "$scratch/fake-bin" "$scratch/repo"
cp "$root/config/captain.conf" "$scratch/home/config/captain.conf"
printf 'demo\t%s\tlocal\t-\n' "$scratch/repo" >"$scratch/home/config/projects.tsv"

git -C "$scratch/repo" init -q
git -C "$scratch/repo" config user.name lint
git -C "$scratch/repo" config user.email lint@example.test
cat >"$scratch/repo/mise.toml" <<'EOF'
[tasks.check]
run = "true"
EOF
git -C "$scratch/repo" add mise.toml
git -C "$scratch/repo" commit -qm initial

cat >"$scratch/fake-bin/mise" <<'EOF'
#!/usr/bin/env bash
sleep 20 &
printf '%s\n' "$!" >"$FAKE_PIDFILE"
printf 'check output from the detached child\n'
EOF
chmod +x "$scratch/fake-bin/mise"

output=$scratch/output
if ! timeout 5 bash -c 'CAP_HOME="$1" FAKE_PIDFILE="$2" PATH="$3:$PATH" "$4/bin/cap-verify" --repo demo | tee "$5" >/dev/null' \
  bash "$scratch/home" "$scratch/fake.pid" "$scratch/fake-bin" "$root" "$output"; then
	printf 'test-verify-output: cap verify did not close its output pipe\n' >&2
	exit 1
fi

grep -q 'check output from the detached child' "$output"
printf 'test-verify-output: detached checks cannot hold caller pipes open\n'
