# shellcheck shell=bash

# Returns 0 when all installers succeed, 1 when any fail, and 2 when none run.
preflight_deps() {
  local tree=$1 ran=0 failed=0

  if [ -f "$tree/mise.toml" ] && have mise; then
    # A cloned worktree has not trusted this mise config yet.
    mise trust --yes "$tree/mise.toml" >/dev/null 2>&1 || true
    preflight_run "$tree" mise install -y
  fi

  if [ -f "$tree/bun.lock" ] || [ -f "$tree/bun.lockb" ]; then
    if have bun; then
      preflight_run "$tree" bun install --frozen-lockfile
    fi
  fi

  if [ -f "$tree/pnpm-lock.yaml" ]; then
    if have pnpm; then
      preflight_run "$tree" pnpm install --frozen-lockfile
    fi
  elif [ -f "$tree/yarn.lock" ]; then
    if have yarn; then
      preflight_run "$tree" yarn install --immutable
    fi
  elif [ -f "$tree/package-lock.json" ]; then
    if have npm; then
      preflight_run "$tree" npm ci
    fi
  fi

  if [ -f "$tree/uv.lock" ]; then
    if have uv; then
      preflight_run "$tree" uv sync
    fi
  elif [ -f "$tree/poetry.lock" ]; then
    if have poetry; then
      preflight_run "$tree" poetry install
    fi
  fi

  if [ -f "$tree/Cargo.lock" ] && have cargo; then
    preflight_run "$tree" cargo fetch
  fi

  if [ -f "$tree/go.sum" ] && have go; then
    preflight_run "$tree" go mod download
  fi

  if [ -f "$tree/Gemfile.lock" ] && have bundle; then
    preflight_run "$tree" bundle install
  fi

  if [ -f "$tree/composer.lock" ] && have composer; then
    preflight_run "$tree" composer install
  fi

  [ "$failed" = 0 ] || return 1
  [ "$ran" = 1 ] || return 2
}

# Record failures instead of stopping so the remaining installers still run.
preflight_run() {
  local tree=$1
  shift

  ran=1
  (cd "$tree" && "$@") || failed=1
}

# Install machine tools that the project does not declare itself.
#
# config/tools/<project>:
#   mise podman
#   mise php@8.4
#   sh   sudo apt-get install -y poppler-utils
preflight_tools() {
  local project=$1 kind rest
  local file=$CAP_HOME/config/tools/$project

  [ -f "$file" ] || return 0

  while read -r kind rest; do
    case ${kind:-} in
    '' | \#*)
      continue
      ;;
    mise)
      if ! have mise; then
        warn "mise is not installed; cannot provide $rest"
        continue
      fi

      have "${rest%%@*}" && continue
      mise use -g "$rest" || warn "could not install $rest"
      ;;
    sh)
      have "$(printf '%s' "$rest" | awk '{print $NF}')" && continue
      eval "$rest" || warn "could not run: $rest"
      ;;
    *)
      warn "$file: unknown kind '$kind'"
      ;;
    esac
  done <"$file"
}

compose_task_exists() {
  local tree=$1 want=$2 tasks

  [ -f "$tree/mise.toml" ] || return 1

  tasks=$(
    {
      grep -oE '^\[tasks\."?[A-Za-z0-9_:.-]+"?\]' "$tree/mise.toml" || true
      awk '/^\[tasks\]$/{f=1;next} /^\[/{f=0} f && /^[A-Za-z0-9_-]+[[:space:]]*=/{sub(/[[:space:]]*=.*/,""); print}' "$tree/mise.toml"
    } |
      sed -E 's/^\[tasks\."?([^"\]]+)"?\]/\1/' |
      sort -u
  )

  printf '%s\n' "$tasks" | grep -qxF "$want"
}

compose_file() {
  local tree=$1 files

  files=$(
    find "$tree" -maxdepth 3 -type f \( \
      -name compose.yaml -o \
      -name compose.yml -o \
      -name docker-compose.yaml -o \
      -name docker-compose.yml \
      \) -print 2>/dev/null || true
  )

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

compose_project_name() {
  local tree=$1 name

  name=$(basename "$(readlink -f "$tree")")
  name=$(printf '%s' "$name" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//; s/[^a-z0-9]*$//')

  if [ -z "$name" ]; then
    name=cap-task
  fi

  printf '%s' "$name"
}

# Resolve teardown before the worktree and its compose config are removed.
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

  if ! engine=$(compose_engine); then
    warn "$tree: compose files found but no docker or podman compose engine is available"
    return 1
  fi

  project_name=$(compose_project_name "$tree")

  if (
    cd "$tree" &&
      COMPOSE_PROJECT_NAME="$project_name" \
        "$engine" compose -f "$file" down --remove-orphans </dev/null
  ); then
    return 0
  fi

  warn "$tree: could not stop the compose stack"
  return 1
}
