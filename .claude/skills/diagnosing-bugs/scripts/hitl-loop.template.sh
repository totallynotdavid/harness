#!/usr/bin/env bash
# Human-in-the-loop reproduction loop.
# Copy the file, edit the scenario, and run it from the project.
# The agent reads the captured values after the user follows the prompts.
#
# Usage:
#   bash hitl-loop.template.sh
#
# `step "<instruction>"` shows an instruction and waits for Enter.
# `capture VAR "<question>"` stores an answer in VAR.
#
# Captured values are printed as KEY=VALUE for the agent to parse.

set -euo pipefail

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$var" '%s' "$answer"
}

# Edit the scenario below.

step "Open the affected screen."

capture ERRORED "Perform the failing action. Did it throw an error? (y/n)"

capture ERROR_MSG "Paste the redacted error message (or 'none'):"

# End of scenario.

printf '\nCaptured values:\n'
printf 'ERRORED=%s\n' "$ERRORED"
printf 'ERROR_MSG=%s\n' "$ERROR_MSG"
