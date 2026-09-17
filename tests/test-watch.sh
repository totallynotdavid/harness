#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

home=$scratch/home
fake_bin=$scratch/bin
mkdir -p "$home/config" "$home/state/tasks/demo" "$home/state/tasks/working" "$fake_bin"
cp "$root/config/captain.conf" "$home/config/captain.conf"

cat >"$fake_bin/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"pane get")
	printf '%s\n' '{"result":{"pane":{"pane_id":"p1"}}}'
	;;
"pane read")
	printf 'agent is working\n'
	;;
"notification show")
	printf '%s\n' "$*" >>"$FAKE_HERDR_LOG"
	;;
*)
	exit 1
	;;
esac
EOF
chmod +x "$fake_bin/herdr"

write_task() {
	local slug=$1
	cat >"$home/state/tasks/$slug/task.env" <<EOF
CAP_SLUG=$slug
CAP_PANE=p1
EOF
}

write_task demo
write_task working
: >"$home/state/tasks/demo/status.log"
: >"$home/state/tasks/working/status.log"

log=$scratch/notifications.log
export FAKE_HERDR_LOG=$log

CAP_HOME=$home PATH="$fake_bin:$PATH" CAP_IDLE_SECS=45 \
	"$root/bin/cap-watch" --task demo --notify --timeout 5 --interval 0.05 \
	>"$scratch/notify.out" 2>&1 &
watcher=$!
sleep 0.2
printf '%s\n' 'done: branch is ready for review' >>"$home/state/tasks/demo/status.log"
wait "$watcher"

grep -Fq 'DONE demo done: branch is ready for review' "$scratch/notify.out"
grep -Fq 'notification show Captain: demo --body DONE: done: branch is ready for review --sound done' "$log"

manual=$(CAP_HOME=$home PATH="$fake_bin:$PATH" CAP_IDLE_SECS=45 \
	"$root/bin/cap-watch" --task demo --timeout 1 --interval 0.05)
grep -Fq 'DONE demo done: branch is ready for review' <<<"$manual"

if CAP_HOME=$home PATH="$fake_bin:$PATH" CAP_IDLE_SECS=45 \
		"$root/bin/cap-watch" --task working --notify --timeout 1 --interval 0.05 \
		>"$scratch/working.out" 2>&1; then
	:
fi

grep -Fq 'TIMEOUT no agent needed input in 1s' "$scratch/working.out"
if grep -Fq 'Captain: working' "$log"; then
	printf 'test-watch: working task unexpectedly notified\n' >&2
	exit 1
fi

printf 'test-watch: detached notification and manual watch cursors agree\n'
