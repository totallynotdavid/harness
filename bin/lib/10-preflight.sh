# shellcheck shell=bash

# Make worktree usable before agent starts. Worktrees have no dependencies
# (node_modules is ignored). Runs every ecosystem's installer whose lockfile
# is present - JS, Python, Rust, Go, Ruby, PHP can all fire in one call.
# bun runs independently of the rest of the JS chain, so a repo with both
# bun.lock and package-lock.json runs both installers. Within pnpm/yarn/npm,
# and within uv/poetry, only the first matching lockfile runs.

# Returns 0 when every installer that ran succeeded, 1 when any failed, and
# 2 when there was nothing to run.
preflight_deps() {
  local tree=$1 ran=0 failed=0

  if [ -f "$tree/mise.toml" ] && have mise; then
    mise trust --yes "$tree/mise.toml" >/dev/null 2>&1 || true
    preflight_run "$tree" mise install -y
  fi
  if [ -f "$tree/bun.lock" ] || [ -f "$tree/bun.lockb" ]; then
    ! have bun || preflight_run "$tree" bun install --frozen-lockfile
  fi
  if [ -f "$tree/pnpm-lock.yaml" ]; then
    ! have pnpm || preflight_run "$tree" pnpm install --frozen-lockfile
  elif [ -f "$tree/yarn.lock" ]; then
    ! have yarn || preflight_run "$tree" yarn install --immutable
  elif [ -f "$tree/package-lock.json" ]; then
    ! have npm || preflight_run "$tree" npm ci
  fi
  if [ -f "$tree/uv.lock" ]; then
    ! have uv || preflight_run "$tree" uv sync
  elif [ -f "$tree/poetry.lock" ]; then
    ! have poetry || preflight_run "$tree" poetry install
  fi
  [ ! -f "$tree/Cargo.lock" ] || ! have cargo || preflight_run "$tree" cargo fetch
  [ ! -f "$tree/go.sum" ] || ! have go || preflight_run "$tree" go mod download
  [ ! -f "$tree/Gemfile.lock" ] || ! have bundle || preflight_run "$tree" bundle install
  [ ! -f "$tree/composer.lock" ] || ! have composer || preflight_run "$tree" composer install

  [ "$failed" = 0 ] || return 1
  [ "$ran" = 1 ] || return 2
}
# One installer, counted in preflight_deps' ran and failed. A failure is
# remembered rather than returned, so every installer still runs and the log
# shows all of them.
preflight_run() {
  local tree=$1
  shift
  ran=1
  (cd "$tree" && "$@") || failed=1
}

# Tools a project needs that nothing in the project declares. Lives in Captain
# (not the project) because Captain is cloned to other machines and most
# projects are clones nobody should restructure. One file per project, kind
# then argument per line:
#   config/tools/<project>
#     mise podman
#     mise php@8.4
#     sh   sudo apt-get install -y poppler-utils
preflight_tools() {
  local project=$1 kind rest
  local f=$CAP_HOME/config/tools/$project
  [ -f "$f" ] || return 0

  while read -r kind rest; do
    case ${kind:-} in
    '' | \#*) continue ;;
    mise)
      have mise || {
        warn "mise is not installed; cannot provide $rest"
        continue
      }
      have "${rest%%@*}" && continue
      mise use -g "$rest" || warn "could not install $rest"
      ;;
    sh)
      have "$(printf '%s' "$rest" | awk '{print $NF}')" && continue
      eval "$rest" || warn "could not run: $rest"
      ;;
    *) warn "$f: unknown kind '$kind'" ;;
    esac
  done <"$f"
}

# A task may own a dev stack even when its checks are not what started it.
# Resolve the teardown command while the worktree still exists, because its
# mise file and compose configuration disappear with the task.
compose_task_exists() {
  local tree=$1 want=$2 tasks
  [ -f "$tree/mise.toml" ] || return 1
  tasks=$(
    {
      grep -oE '^\[tasks\."?[A-Za-z0-9_:.-]+"?\]' "$tree/mise.toml" || true
      awk '/^\[tasks\]$/{f=1;next} /^\[/{f=0} f && /^[A-Za-z0-9_-]+[[:space:]]*=/{sub(/[[:space:]]*=.*/,""); print}' "$tree/mise.toml"
    } | sed -E 's/^\[tasks\."?([^"\]]+)"?\]/\1/' | sort -u
  )
  printf '%s\n' "$tasks" | grep -qxF "$want"
}

compose_file() {
  local tree=$1 files
  files=$(find "$tree" -maxdepth 3 -type f \( \
    -name compose.yaml -o -name compose.yml -o \
    -name docker-compose.yaml -o -name docker-compose.yml \
    \) -print 2>/dev/null || true)
  [ -n "$files" ] || return 0
  printf '%s\n' "$files" | sort | head -1
}

compose_engine() {
  if have docker && docker compose version >/dev/null 2>&1; then
    printf docker
    return 0
  fi
  if have podman && podman compose version >/dev/null 2>&1; then
    printf podman
    return 0
  fi
  return 1
}

# Stop a task-owned dev stack before cap-drop removes the files needed to find
# it. A project-specific dev:down task gets first choice; the compose fallback
# uses the worktree basename as the same stable project name the task used.
compose_down() {
  local tree=$1 file engine project_name

  if compose_task_exists "$tree" dev:down; then
    if (cd "$tree" && mise run dev:down </dev/null); then
      return 0
    fi
    warn "$tree: mise run dev:down failed; trying compose teardown"
  fi

  file=$(compose_file "$tree")
  [ -n "$file" ] || return 0
  engine=$(compose_engine) || {
    warn "$tree: compose files found but no docker or podman compose engine is available"
    return 1
  }
  project_name=$(basename "$(readlink -f "$tree")" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//; s/[^a-z0-9]*$//')
  [ -n "$project_name" ] || project_name=cap-task
  if (cd "$tree" && COMPOSE_PROJECT_NAME="$project_name" "$engine" compose -f "$file" down --remove-orphans </dev/null); then
    return 0
  fi
  warn "$tree: could not stop the compose stack"
  return 1
}
