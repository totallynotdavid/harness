#!/usr/bin/env bash
# Tell the captain what is waiting for a decision, without being asked.
#
# Across two sessions on 2026-09-09 the captain typed "check progress" eight
# times, plus "i think it finished?", "did we push to a remote?" and "do we have
# uncommitted, unpushed work?". Every one of those answers already existed on
# disk. Polling is the captain paying a turn for state a hook can hand over for
# free.
#
# This runs on every prompt and prints nothing at all while nothing needs him,
# so it costs no context until the moment it has something to say.
set -uo pipefail

. "$(dirname "$(readlink -f "$0")")/../lib.sh" 2>/dev/null || exit 0

cat >/dev/null

lines=""
add() { lines="$lines$1"$'\n'; }

for slug in $(task_slugs); do
	status=$(task_status_latest "$slug" 2>/dev/null || true)
	project=$(task_field "$slug" CAP_PROJECT 2>/dev/null || true)

	case $status in
	done)
		add "  $slug ($project) is done and unlanded: cap check $slug"
		;;
	blocked | needs-input | failed)
		note=$(grep -E "^$status:" "$TASKS/$slug/status.log" 2>/dev/null | tail -1 || true)
		add "  $slug ($project) is $status: ${note#*: }"
		;;
	working)
		# A task can stop existing without saying so. relq-lower-floor read as
		# "working" in cap crew while its pane was absent from herdr's registry
		# entirely, and the captain noticed before the harness did.
		if ! pane_live "$slug" 2>/dev/null; then
			add "  $slug ($project) says working but its pane is gone: cap peek $slug"
		fi
		;;
	esac
done

# Captain's own state directory has no locks. Three sessions were live in this
# hub at once on 2026-09-09, and two concurrent cap-gate runs on local-env each
# overwrote the other's report.
#
# Walk up to this hook's own session so it does not count itself, and skip the
# harness's own sessions: cap ask and cap spawn pass the whole brief as the last
# argument, which an interactive session never has.
self_pid=$$
while [ "$self_pid" -gt 1 ]; do
	if [ "$(cat "/proc/$self_pid/comm" 2>/dev/null || true)" = claude ]; then break; fi
	self_pid=$(awk '{print $4}' "/proc/$self_pid/stat" 2>/dev/null || echo 1)
done

others=0
for pid in $(pgrep -x claude 2>/dev/null || true); do
	[ "$pid" != "$self_pid" ] || continue
	[ "$(readlink "/proc/$pid/cwd" 2>/dev/null || true)" = "$CAP_HOME" ] || continue
	last=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | tail -1 || true)
	case $last in -*) ;; *) [ "${#last}" -lt 40 ] || continue ;; esac
	others=$((others + 1))
done
if [ "$others" -gt 0 ]; then
	add "  $others other captain session(s) share this hub with no locking: cap sessions"
fi

if [ -n "$lines" ]; then
	printf 'Waiting on you:\n%s' "$lines"
fi
exit 0
