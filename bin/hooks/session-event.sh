#!/usr/bin/env bash
# Record a session event for whoever dispatched the session.
#
# `turn`: a turn ended. The session stays open between turns, so a
# dispatcher waits for a new file in CAP_TURN_DIR, never for the process to
# exit. `start`: the session began, and its payload names the transcript
# before any turn has ended.
#
# This hook must never fail. A hook that errors is a turn the agent cannot
# finish.
set -u

dir=${CAP_TURN_DIR:-}
if [ -z "$dir" ] || ! mkdir -p "$dir" 2>/dev/null; then
	cat >/dev/null
	exit 0
fi

# Written whole, then renamed, so a reader never parses half a payload.
tmp=$(mktemp "$dir/.event.XXXXXX" 2>/dev/null) || { cat >/dev/null; exit 0; }
cat >"$tmp"
case ${1:-turn} in
start) name=session.start ;;
*) name=$(date +%s%N).json ;;
esac
mv "$tmp" "$dir/$name" 2>/dev/null || rm -f "$tmp"
exit 0
