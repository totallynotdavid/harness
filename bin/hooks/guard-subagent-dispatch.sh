#!/usr/bin/env bash
# Block delegation tools. Use cap spawn instead.
#
# cap spawn tracks agents so crew, watch, and land can manage them.
# Set CAP_ALLOW_SUBAGENT=1 to allow research-only delegation.
set -u
[ -n "${CAP_ALLOW_SUBAGENT:-}" ] && exit 0

input=$(cat)

# Allow everything if jq is unavailable.
command -v jq >/dev/null 2>&1 || exit 0

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[ -n "$tool" ] || exit 0

# Allow MCP tools.
case "$tool" in
mcp__*) exit 0 ;;
esac

lc=$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')

# Allow tools that only check or stop work.
case "$lc" in
taskoutput | taskstop | listagents | cronlist) exit 0 ;;
esac

case "$lc" in
*agent* | *task* | *spawn* | *dispatch* | *handoff* | *worktree* | *cron* | *sendmessage* | *remote*)
  printf 'BLOCKED: %s can delegate work. Use cap spawn <slug> <project> instead. Override with CAP_ALLOW_SUBAGENT=1.\n' "$tool" >&2
  exit 2
  ;;
esac

exit 0
