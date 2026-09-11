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

# A task owned by a live session other than this one is that session's to
# watch, not this one's to nag about.
me=$(session_identity)
for slug in $(task_slugs); do
	owner=$(task_field "$slug" CAP_OWNER 2>/dev/null || true)
	if [ -n "$owner" ] && [ "$owner" != "$me" ] && session_alive "$owner"; then
		continue
	fi

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

if [ -n "$lines" ]; then
	printf 'Waiting on you:\n%s' "$lines"
fi
exit 0
