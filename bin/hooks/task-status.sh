#!/usr/bin/env bash
# Tell the captain what is waiting for a decision, without being asked.
#
# Task state is already on disk. Report decisions that are waiting for the
# captain when a prompt starts, so the captain does not need to poll for it.
#
# This runs on every prompt and prints nothing at all while nothing needs him,
# so it costs no context until the moment it has something to say.
set -uo pipefail

. "$(dirname "$(readlink -f "$0")")/../lib.sh" 2>/dev/null || exit 0

cat >/dev/null

lines=""
add() { lines="$lines$1"$'\n'; }

completions=$(cap_completion_report 2>/dev/null || true)
while IFS= read -r completion; do
  [ -n "$completion" ] && add "$completion"
done <<<"$completions"

for slug in $(task_slugs); do
  (task_load "$slug") 2>/dev/null || continue

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
    # gate_fingerprint hashes the working tree, so a task fresh off a
    # passing gate is normally still dirty and cap deliver refuses that.
    tree=$(task_field "$slug" CAP_TREE 2>/dev/null || true)
    if [ -n "$tree" ] && [ "$(git_dirty "$tree")" != 0 ]; then
      add "  $slug ($project) is ready to deliver: cap commit $slug && cap deliver $slug"
    else
      add "  $slug ($project) is ready to deliver: cap deliver $slug"
    fi
    ;;
  blocked | needs-input | failed)
    # A reason the agent logged before its last delivered message is
    # from a turn that has already ended - herdr can report the same
    # verb again for an unrelated prompt with nothing new logged, and
    # naming the old reason then points the captain at the wrong one.
    note=$(awk -v state="$state:" '
			index($0, "working:") == 1 { working = NR }
			index($0, state) == 1 { line = NR; text = $0 }
			END { if (line != "" && (working == "" || line > working)) print text }
		' "$TASKS/$slug/status.log" 2>/dev/null || true)
    if [ -n "$note" ]; then
      add "  $slug ($project) is $state: ${note#*: }"
    else
      add "  $slug ($project) is $state"
    fi
    ;;
  idle)
    add "  $slug ($project) has stopped and is waiting on you: cap peek $slug"
    ;;
  exited)
    add "  $slug ($project) exited: cap deliver $slug or cap drop $slug"
    ;;
  esac

  queue_pending "$slug" 2>/dev/null &&
    add "  $slug ($project) has a message queued that has not gone in yet"
done

if [ -n "$lines" ]; then
  printf 'Waiting on you:\n%s' "$lines"
fi
exit 0
