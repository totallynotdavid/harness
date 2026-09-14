#!/usr/bin/env bash
# test-doctor - exercise SSH-backed doctor comparison without a network host.
set -euo pipefail

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
scratch=$(mktemp -d)
mkdir -p "$scratch/bin"
cat >"$scratch/bin/ssh" <<'EOF'
#!/usr/bin/env bash
host=$1
shift
unset CAP_HOME
if [ "$host" = no-cap-host ]; then
	PATH=/usr/bin:/bin
else
	PATH="$FAKE_REMOTE_BIN:$PATH"
fi
exec "$@"
EOF
chmod +x "$scratch/bin/ssh"

mkdir -p "$scratch/remote-bin"
ln -s "$root/bin/cap" "$scratch/remote-bin/cap"

if ! result=$(HOME="$scratch/home" CAP_HOME="$root" FAKE_REMOTE_BIN="$scratch/remote-bin" PATH="$scratch/bin:$PATH" "$root/bin/cap-doctor" --remote lint-host); then
  printf 'test-doctor: SSH-backed comparison failed\n' >&2
  exit 1
fi

[ "$result" = 'no differences' ]
[ -L "$scratch/home/.local/bin/cap" ]
[ "$(readlink -f "$scratch/home/.local/bin/cap")" = "$root/bin/cap" ]
[ "$(grep -Fc 'export PATH="$HOME/.local/bin:$PATH"' "$scratch/home/.profile")" -eq 1 ]
if HOME="$scratch/home" CAP_HOME="$root" FAKE_REMOTE_BIN="$scratch/remote-bin" PATH="$scratch/bin:$PATH" "$root/bin/cap-doctor" --remote no-cap-host >/dev/null 2>&1; then
  printf 'test-doctor: remote discovery accepted an unregistered checkout\n' >&2
  exit 1
fi
printf 'test-doctor: remote Captain discovery and comparison work\n'
