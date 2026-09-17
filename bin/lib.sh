# bin/lib.sh - shared Captain configuration and module loader.
# shellcheck shell=bash

set -euo pipefail

CAP_HOME=${CAP_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export CAP_HOME

CAP_BIN=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
export CAP_BIN

# shellcheck source=config/captain.conf
. "$CAP_HOME/config/captain.conf"

PROJECTS=$CAP_HOME/config/projects.tsv
LOCAL_INDEX=$CAP_HOME/state/local-paths.tsv
TASKS=$CAP_HOME/state/tasks
COMPLETIONS=$CAP_HOME/state/completions

lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)
modules=(
  00-core
  10-preflight
  20-resources
  30-ownership
  40-process
  50-locks
  60-task
  70-queue
  80-state
  90-git
  95-stack
  99-dispatch
)
for module in "${modules[@]}"; do
  . "$lib_dir/$module.sh"
done
unset lib_dir module modules
