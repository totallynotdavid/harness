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
	# A task free for this session (task_owner_free: unowned, dead-owned,
	# owned by this session or its own dispatched agent, see bin/lib.sh)
	# is safe to report on; one held by another live session is that
	# session's to watch, not this one's to nag about.
	task_owner_free "$slug" || continue

	# task_state settles *whether* the task has stopped from herdr and
	# *whether* it is ready from gate.json - never from a word the agent
	# logged. The log names a reason only for the three verbs that carry
	# one; anything else that has stopped just needs a look.
	state=$(task_state "$slug" 2>/dev/null || true)
	project=$(task_field "$slug" CAP_PROJECT 2>/dev/null || true)

	case $state in
	ready)
		# gate_ready is true the moment gate A+B pass the tree as it stands,
		# uncommitted or not (gate_fingerprint hashes the working tree, and
		# cap-gate runs before cap-commit), so a task fresh off a passing
		# gate is normally still dirty. cap land refuses that, same as
		# cap-gate's own "cap commit && cap land" line below - name the
		# same next step here instead of one that dies.
		tree=$(task_field "$slug" CAP_TREE 2>/dev/null || true)
		if [ -n "$tree" ] && [ "$(git_dirty "$tree")" != 0 ]; then
			add "  $slug ($project) is ready to land: cap commit $slug && cap land $slug"
		else
			add "  $slug ($project) is ready to land: cap land $slug"
		fi
		;;
	blocked | needs-input | failed)
		note=$(grep -E "^$state:" "$TASKS/$slug/status.log" 2>/dev/null | tail -1 || true)
		add "  $slug ($project) is $state: ${note#*: }"
		;;
	idle)
		add "  $slug ($project) has stopped and is waiting on you: cap peek $slug"
		;;
	exited)
		add "  $slug ($project) exited: cap land $slug or cap drop $slug"
		;;
	esac

	queue_pending "$slug" 2>/dev/null &&
		add "  $slug ($project) has a message queued that has not gone in yet"
done

if [ -n "$lines" ]; then
	printf 'Waiting on you:\n%s' "$lines"
fi
exit 0
