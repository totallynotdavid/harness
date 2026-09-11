# bin/lib.sh - shared helpers for cap commands.
# shellcheck shell=bash
# shellcheck disable=SC2034 # globals here are read by the bin/cap-* scripts that source this file

set -euo pipefail

CAP_HOME=${CAP_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export CAP_HOME

# shellcheck source=config/captain.conf
. "$CAP_HOME/config/captain.conf"

PROJECTS=$CAP_HOME/config/projects.tsv
TASKS=$CAP_HOME/state/tasks

die() {
  printf 'cap: %s\n' "$*" >&2
  exit 1
}
warn() { printf 'cap: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s; }
stamp() { date +%Y-%m-%d; }

# A session id for a headless harness launch. uuidgen is not guaranteed
# present, so this falls back to the kernel's own generator; die with a
# reason rather than let a missing fallback exit callers silently under set -e.
new_uuid() {
  if have uuidgen; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    die "no uuid source on this host (need uuidgen or /proc/sys/kernel/random/uuid)"
  fi
}

# projects.tsv: name, path, mode, model.

proj_field() {
  [ -f "$PROJECTS" ] || die "no registry; run: cap map --sync"
  awk -F'\t' -v n="$1" -v c="$2" '$1==n {print $c; found=1} END{exit !found}' "$PROJECTS" ||
    die "unknown project '$1' (cap map --sync to register)"
}
proj_path() { proj_field "$1" 2; }
proj_mode() {
  m=$(proj_field "$1" 3)
  printf '%s' "${m:-pr}"
}
proj_model() { proj_field "$1" 4; }

task_dir() { printf '%s/%s' "$TASKS" "$1"; }
task_load() {
  local f=$TASKS/$1/task.env
  [ -f "$f" ] || die "no such task '$1'"

  # shellcheck disable=SC1090
  . "$f"
}
task_slugs() { [ -d "$TASKS" ] && ls -1 "$TASKS" 2>/dev/null || true; }

# Make worktree usable before agent starts. Worktrees have no dependencies
# (node_modules is ignored). Runs every ecosystem's installer whose lockfile
# is present - JS, Python, Rust, Go, Ruby, PHP can all fire in one call.
# bun runs independently of the rest of the JS chain, so a repo with both
# bun.lock and package-lock.json runs both installers. Within pnpm/yarn/npm,
# and within uv/poetry, only the first matching lockfile runs.

preflight_deps() {
  local tree=$1 ran=0

  if [ -f "$tree/mise.toml" ] && have mise; then
    mise trust --yes "$tree/mise.toml" >/dev/null 2>&1 || true
    (cd "$tree" && mise install -y) && ran=1
  fi
  if [ -f "$tree/bun.lock" ] || [ -f "$tree/bun.lockb" ]; then
    have bun && (cd "$tree" && bun install --frozen-lockfile) && ran=1
  fi
  if [ -f "$tree/pnpm-lock.yaml" ]; then
    have pnpm && (cd "$tree" && pnpm install --frozen-lockfile) && ran=1
  elif [ -f "$tree/yarn.lock" ]; then
    have yarn && (cd "$tree" && yarn install --immutable) && ran=1
  elif [ -f "$tree/package-lock.json" ]; then
    have npm && (cd "$tree" && npm ci) && ran=1
  fi
  if [ -f "$tree/uv.lock" ]; then
    have uv && (cd "$tree" && uv sync) && ran=1
  elif [ -f "$tree/poetry.lock" ]; then
    have poetry && (cd "$tree" && poetry install) && ran=1
  fi
  [ ! -f "$tree/Cargo.lock" ] || { have cargo && (cd "$tree" && cargo fetch) && ran=1; }
  [ ! -f "$tree/go.sum" ] || { have go && (cd "$tree" && go mod download) && ran=1; }
  [ ! -f "$tree/Gemfile.lock" ] || { have bundle && (cd "$tree" && bundle install) && ran=1; }
  [ ! -f "$tree/composer.lock" ] || { have composer && (cd "$tree" && composer install) && ran=1; }

  # A project whose setup cannot be inferred is not a project to refuse. Say
  # nothing and let the agent start.
  [ "$ran" = 1 ]
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
      have mise || { warn "mise is not installed; cannot provide $rest"; continue; }
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

# Which commits the project's own tooling has actually passed on. cap-spawn
# reads this to refuse forking a second task from a base nothing has verified.
VERIFIED=$CAP_HOME/state/verified

verified_record() {
  local project=$1 sha=$2
  [ -n "$sha" ] || return 0
  mkdir -p "$VERIFIED/$project"
  : >"$VERIFIED/$project/$sha"
}

verified_is() {
  local project=$1 sha=$2
  [ -n "$sha" ] && [ -f "$VERIFIED/$project/$sha" ]
}

# What one task of a project actually costs in memory, measured from a real
# cap-verify run (project_peak_record below) rather than guessed, so the
# CAP_MIN_FREE_MB default only ever covers a project that hasn't run yet.
# Parallelism is faster only while every task's working set fits at once.
PEAKS=$CAP_HOME/state/peaks

project_peak_mb() {
  local f=$PEAKS/$1 v=""
  [ -f "$f" ] && v=$(cat "$f" 2>/dev/null || true)
  case $v in
  '' | *[!0-9]*) printf '%s' "${CAP_MIN_FREE_MB:-1200}" ;;
  *) printf '%s' "$v" ;;
  esac
}

# Keep the high-water mark, never the latest reading. A run that happened to be
# cheap must not license a fan-out the expensive run cannot survive.
project_peak_record() {
  local project=$1 mb=$2 cur=0
  case $mb in '' | *[!0-9]*) return 0 ;; esac
  mkdir -p "$PEAKS"
  # Compare against what was recorded, never against the fallback. Comparing
  # with project_peak_mb means a first real reading below the default is
  # discarded and the guess survives forever.
  cur=$(cat "$PEAKS/$project" 2>/dev/null || echo 0)
  case $cur in '' | *[!0-9]*) cur=0 ;; esac
  if [ "$mb" -gt "$cur" ]; then printf '%s\n' "$mb" >"$PEAKS/$project"; fi
}

# How many more tasks this box can hold for a project, right now.
project_slots() {
  local project=$1 avail peak
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  peak=$(project_peak_mb "$project")
  [ "$peak" -gt 0 ] || peak=1200
  printf '%s' "$((avail / peak))"
}

# The project a wave file names in its header.
wave_project() {
  sed -n 's/^#[[:space:]]*project:[[:space:]]*//p' "$1" 2>/dev/null | head -1
}

# Path ownership guard prevents collisions across tasks. Tasks declare paths
# in state/tasks/<slug>/owns (one per line), never in task.env (which is sourced
# and would parse multi-glob as shell). Globs use git's :(glob) pathspec.

owns_read() {
  local f=$TASKS/$1/owns
  [ -f "$f" ] || return 0
  tr '\n' ' ' <"$f" | sed 's/  */ /g; s/^ //; s/ $//'
}

owns_write() {
  local slug=$1
  shift
  mkdir -p "$TASKS/$slug"
  printf '%s\n' "$@" >"$TASKS/$slug/owns"
}

# The literal prefix of a glob, up to the first wildcard. Two globs whose
# prefixes contain one another can collide on a file that does not exist yet,
# which is what .env.example did.
owns_prefix() {
  local g=${1%%[*?[]*}
  printf '%s' "${g%/}"
}

# Every file in a worktree that a glob set claims, tracked and untracked alike.
owns_files() {
  local tree=$1 g
  shift
  for g in "$@"; do
    git -C "$tree" ls-files -co --exclude-standard -- ":(glob)$g" 2>/dev/null || true
  done | sort -u
}

# Print what two glob sets share and return 0, or return 1 when they are
# disjoint. Concrete files first, then prefixes for ground neither has touched.
owns_overlap() {
  local tree=$1 shared pa pb
  local -a a b
  read -r -a a <<<"$2"
  read -r -a b <<<"$3"
  [ "${#a[@]}" -gt 0 ] && [ "${#b[@]}" -gt 0 ] || return 1

  shared=$(comm -12 \
    <(owns_files "$tree" "${a[@]}") \
    <(owns_files "$tree" "${b[@]}") 2>/dev/null || true)
  if [ -n "$shared" ]; then
    printf '%s\n' "$shared"
    return 0
  fi

  for pa in "${a[@]}"; do
    pa=$(owns_prefix "$pa")/
    for pb in "${b[@]}"; do
      pb=$(owns_prefix "$pb")/
      case $pa in "$pb"*) printf '%s overlaps %s\n' "${pa%/}" "${pb%/}"; return 0 ;; esac
      case $pb in "$pa"*) printf '%s overlaps %s\n' "${pa%/}" "${pb%/}"; return 0 ;; esac
    done
  done
  return 1
}

# Glob to anchored regex per git's :(glob) rules: ** crosses dirs, * does not.
# No wildcard means directory claim (everything under it) so regex matches both
# the dir itself and files inside it, not just `^dir$`.
owns_regex() {
  case $1 in
  *[*?]*) ;;
  *) printf '^%s(/.*)?$' "$(printf '%s' "$1" | sed 's/[].^$+(){}|\[]/\\&/g')"; return ;;
  esac
  printf '%s' "$1" | awk '{
    out = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "*") {
        if (substr($0, i + 1, 1) == "*") { out = out ".*"; i++ }
        else { out = out "[^/]*" }
      } else if (c == "?") { out = out "[^/]" }
      else if (index(".^$+(){}[]|\\", c) > 0) { out = out "\\" c }
      else { out = out c }
    }
    print "^" out "$"
  }'
}

# Whether a repository-relative path falls inside a glob set.
owns_claims() {
  local path=$1 g
  shift
  for g in "$@"; do
    if printf '%s\n' "$path" | grep -qE "$(owns_regex "$g")"; then
      return 0
    fi
  done
  return 1
}

# Whether any live task in the same project already claims this ground. Prints
# the claimants and returns 0 when it finds one.
owns_taken() {
  local project=$1 tree=$2 globs=$3 self=${4:-} other otree hit found=1
  for other in $(task_slugs); do
    [ "$other" != "$self" ] || continue
    [ "$(task_field "$other" CAP_PROJECT 2>/dev/null || true)" = "$project" ] || continue
    otree=$(task_field "$other" CAP_TREE 2>/dev/null || true)
    [ -n "$otree" ] && [ -e "$otree/.git" ] || continue
    hit=$(owns_overlap "$tree" "$globs" "$(owns_read "$other")") || continue
    printf '%s claims:\n' "$other"
    printf '%s\n' "$hit" | sed 's/^/    /'
    found=0
  done
  return $found
}

# One cap command per task at a time. Gate, check, commit, and land all
# read-modify-write state/tasks/<slug>/. Lock is released on process exit.
task_lock() {
  local slug=$1
  local dir=$TASKS/$slug
  # Re-entrant: cap land can release via cap drop without deadlocking. The
  # marker is exported, so only the holder's children inherit it.
  case " ${CAP_LOCKS:-} " in *" $slug "*) return 0 ;; esac
  mkdir -p "$dir"
  exec {CAP_LOCK_FD}>>"$dir/.lock"
  if ! flock -n "$CAP_LOCK_FD"; then
    die "$slug is already held by $(cat "$dir/.lock" 2>/dev/null || echo 'another cap command')"
  fi
  printf 'pid %s (%s) since %s\n' "$$" "$(basename "$0")" "$(date -u +%H:%M:%SZ)" >"$dir/.lock"
  CAP_LOCKS="${CAP_LOCKS:-} $slug"
  export CAP_LOCKS
}

# Read a task field without sourcing its record.
task_field() {
  local f=$TASKS/$1/task.env
  [ -f "$f" ] || return 1
  awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/, ""); print; exit}' "$f"
}

# Update a task field without reordering the record.
task_env_set() {
  local f=$TASKS/$1/task.env tmp
  [ -f "$f" ] || die "no such task '$1'"
  tmp=$(mktemp)
  awk -F= -v k="$2" -v v="$3" '
    $1==k { print k "=" v; seen=1; next }
    { print }
    END { if (!seen) print k "=" v }
  ' "$f" >"$tmp"
  mv "$tmp" "$f"
}

task_children() {
  local s
  [ -n "${1:-}" ] || return 0
  for s in $(task_slugs); do
    [ "$(task_field "$s" CAP_PARENT)" = "$1" ] && printf '%s\n' "$s"
  done
  return 0
}

require_herdr() {
  { [ -n "${HERDR_ENV:-}" ] && have herdr; } && return
  die "herdr not detected: HERDR_ENV unset or herdr not on PATH"
}

# Create a Herdr tab and return its pane and tab IDs.
herdr_open() {
  local json pane tab
  json=$(herdr tab create --cwd "$1" --label "$2" --no-focus 2>/dev/null) || die "herdr tab create failed"
  pane=$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty')
  tab=$(printf '%s' "$json" | jq -r '.result.tab.tab_id // empty')
  [ -n "$pane" ] || die "herdr tab create returned no pane id"
  printf '%s %s' "$pane" "$tab"
}

task_pane() { awk -F= '$1=="CAP_PANE"{print $2}' "$TASKS/$1/task.env" 2>/dev/null; }

# Run a command in a pane via temp script. Typing directly overruns tty
# line-length limit with large prompts; "bash <script>" never does.
pane_launch() {
  local pane=$1 script
  shift
  script=$(mktemp)
  { printf '#!/usr/bin/env bash\n'; printf 'exec %s\n' "$(printf '%q ' "$@")"; } > "$script"
  herdr pane run "$pane" "bash $script" >/dev/null 2>&1 || die "herdr pane run failed"
}

pane_live() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane get "$p" >/dev/null 2>&1
}
pane_tail() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane read "$p" --source visible --lines "${2:-60}" 2>/dev/null || true
}
pane_kill() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane close "$p" >/dev/null 2>&1
}

# Send text without pressing Enter. Split into chunks because herdr pane
# send-text has no backpressure and target TUI can drop large messages
# mid-word. Chunk size and pause are empirically safe margins below observed
# drop threshold.
pane_send() {
  local p text chunk_size i n
  p=$(task_pane "$1")
  [ -n "$p" ] || return 0
  text=$2
  chunk_size=400
  n=${#text}
  i=0
  while [ "$i" -lt "$n" ]; do
    herdr pane send-text "$p" "${text:$i:$chunk_size}" >/dev/null 2>&1
    i=$((i + chunk_size))
    if [ "$i" -lt "$n" ]; then
      sleep 0.15
    fi
  done
}
pane_enter() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane send-keys "$p" enter >/dev/null 2>&1 || true
}

# herdr's reported status, not a guess from output staleness.
pane_agent_status() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] || { printf 'unknown'; return; }
  herdr agent get "$p" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null ||
    printf 'unknown'
}

# The context-used percentage from the pane's own status line, whichever
# harness's format it is in ("Context 46% used" from codex, "ctx 37% used"
# from claude). Empty if none is visible yet.
pane_context_pct() {
  pane_tail "$1" 8 | grep -oiE '(context|ctx) [0-9]+% used' | tail -1 | grep -oE '[0-9]+'
}

# A task is idle when its recent output stops changing.
task_idle_age() {
  local w=$TASKS/$1/watch h
  h=$(pane_tail "$1" 40 | cksum | cut -d' ' -f1)

  if [ -f "$w" ] && [ "$(cut -d' ' -f1 "$w")" = "$h" ]; then
    printf '%s 0' "$(($(now) - $(cut -d' ' -f2 "$w")))"
  else
    printf '%s %s\n' "$h" "$(now)" >"$w"
    printf '0 1'
  fi
}

# Read complete status lines appended since the task's last status check.
task_status_lines() {
  local f=$TASKS/$1/status.log cursor start line bytes
  local LC_ALL=C

  [ -f "$f" ] || return 0

  cursor=$TASKS/$1/status.cursor
  start=0
  if [ -f "$cursor" ]; then
    IFS= read -r start <"$cursor" || start=0
    case $start in
      ''|*[!0-9]*) start=0 ;;
    esac
  fi

  bytes=$(wc -c <"$f")
  [ "$start" -le "$bytes" ] || start=0

  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    start=$((start + ${#line} + 1))
  done < <(tail -c +$((start + 1)) "$f")

  printf '%s\n' "$start" >"$cursor"
}

task_status_verb() {
  case $1 in
    done:*)       printf 'done' ;;
    blocked:*)    printf 'blocked' ;;
    needs-input:*) printf 'needs-input' ;;
    failed:*)     printf 'failed' ;;
    working:*)    printf 'working' ;;
  esac
}

# Return the latest recognized status event in the task's append-only log.
task_status_latest() {
  local f=$TASKS/$1/status.log line verb latest=
  [ -f "$f" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(task_status_verb "$line")
    [ -n "$verb" ] && latest=$verb
  done <"$f"

  if [ -n "$latest" ]; then
    printf '%s' "$latest"
  fi
}

git_dirty() { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }

# Sync a worktree onto the current tip of its base branch before review, so
# an unrelated task landing on base since this one branched never gets
# misread by a gate as this branch deleting/reverting that feature (see
# docs/pipeline-notes.md, "Stale-base false positives"). Safe by
# construction: proceeds only when both the merge and any stash reapply are
# conflict-free. On any conflict it leaves the worktree exactly as a human
# doing this by hand would (merge aborted, or mid-conflict with the original
# work recoverable from the stash) and reports rather than guessing.
# Returns 1 only when the worktree is left mid-conflict and should not be
# gated this round.
sync_base() {
  local tree=$1 base=$2 base_tip merge_base dirty stashed=0

  base_tip=$(git -C "$tree" rev-parse "$base" 2>/dev/null) || return 0
  merge_base=$(git -C "$tree" merge-base HEAD "$base" 2>/dev/null) || return 0
  [ "$base_tip" = "$merge_base" ] && return 0 # already current

  dirty=$(git_dirty "$tree")
  if [ "$dirty" != 0 ]; then
    git -C "$tree" stash push -u -m "cap-gate auto-sync" >/dev/null 2>&1 || {
      warn "$tree: could not stash before syncing onto $base; gating the stale diff as-is"
      return 0
    }
    stashed=1
  fi

  if ! git -C "$tree" merge "$base" --no-edit >/dev/null 2>&1; then
    git -C "$tree" merge --abort >/dev/null 2>&1
    [ "$stashed" = 1 ] && git -C "$tree" stash pop >/dev/null 2>&1
    warn "$tree: $base moved and merging it conflicts; gating the stale diff as-is (see docs/pipeline-notes.md)"
    return 0
  fi

  if [ "$stashed" = 1 ] && ! git -C "$tree" stash pop >/dev/null 2>&1; then
    warn "$tree: merged $base, but reapplying stashed work conflicts. The worktree is now mid-conflict; not gating this round. Resolve it (see docs/pipeline-notes.md), ideally by asking the task's own agent to run 'git stash pop' and fix the conflict itself."
    return 1
  fi

  printf 'cap: synced %s onto current %s before gating\n' "$tree" "$base" >&2
  return 0
}

# The commit to diff a worktree against: where its branch actually left base,
# not base's current tip. A sibling task landing into base after this branch
# was cut would otherwise show up as this branch's own change, in a diff, a
# fingerprint, or a reviewer's own `git diff` command. Used by cap-check,
# cap-cleanup, cap-gate, and gate_fingerprint below.
diff_base() {
  local tree=$1 base=$2 mb
  mb=$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null) || true
  printf '%s' "${mb:-$base}"
}

# Fingerprint of exactly what a gate reviews: full diff plus untracked files.
# Same fingerprint means identical code reviewed, independent of commits or
# stash round-trips. Untracked files must be included, since a diff alone
# says nothing about a new file the deliverable adds.
gate_fingerprint() {
  local tree=$1 base=$2 f
  base=$(diff_base "$tree" "$base")
  {
    git -C "$tree" diff "$base" 2>/dev/null || true
    # Hash each path as well as its bytes, so a rename is a new fingerprint.
    while IFS= read -r -d '' f; do
      printf '=== %s\n' "$f"
      cat -- "$tree/$f" 2>/dev/null || true
    done < <(git -C "$tree" ls-files --others --exclude-standard -z 2>/dev/null | sort -z)
  } | sha256sum | cut -d' ' -f1
}

# The exact-line GATE: PASS / GATE: FAIL verdict from a gate report. Skips
# fenced code (``` or ~~~, 3+, matched by character and length per
# CommonMark - an opener never closed swallows the rest of the report) and
# four-or-more-space or tab-indented lines, then strips markdown structure -
# heading (# on both ends), list, blockquote, bold/italic, trailing period -
# never quote marks or backticks. Last matching line wins.
gate_verdict() {
  [ -f "$1" ] || { printf 'UNKNOWN'; return; }
  local body
  # grep -v exits 1, not just prints nothing, on a zero-byte report - what
  # cap-gate feeds this after a session-limit rejection. Harmless today only
  # because the caller uses a command substitution, where bash does not
  # apply set -e to the command inside.
  body=$(grep -v '^[[:space:]]*$' "$1" || true)
  printf '%s\n' "$body" |
    awk '
      # <=3 leading spaces then a run of ch (backtick or tilde). An opener
      # may carry an info string after the run (```sh); a closer may not -
      # only trailing spaces/tabs, checked by the caller when it matters.
      function fence_run(line, ch,    lead, rest, run) {
        lead = 0
        while (lead < 3 && substr(line, lead + 1, 1) == " ") lead++
        rest = substr(line, lead + 1)
        run = 0
        while (substr(rest, run + 1, 1) == ch) run++
        return run
      }
      function only_trailing_space(line, ch, run,    lead, rest, trail) {
        lead = 0
        while (lead < 3 && substr(line, lead + 1, 1) == " ") lead++
        rest = substr(line, lead + 1)
        trail = substr(rest, run + 1)
        gsub(/[ \t]/, "", trail)
        return trail == ""
      }
      {
        if (in_fence) {
          # A closer must be the same character, at least as long as the
          # opener, and bare - anything else, including the other fence
          # character or an info string, is still content.
          n = fence_run($0, fch)
          if (n >= flen && only_trailing_space($0, fch, n)) in_fence = 0
          next
        }
        n = fence_run($0, "`")
        if (n >= 3) { in_fence = 1; fch = "`"; flen = n; next }
        n = fence_run($0, "~")
        if (n >= 3) { in_fence = 1; fch = "~"; flen = n; next }
        if ($0 ~ /^(    |\t)/) next
        print
      }
    ' |
    sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]*//; s/^[[:space:]#>*_-]*//; s/[[:space:]#*_.]*$//' |
    grep -E '^GATE: (PASS|FAIL)$' | tail -1 |
    grep -oE 'PASS|FAIL' || printf 'UNKNOWN'
}

# Record one profile's verdict for a task at the fingerprint it reviewed.
# state/tasks/<slug>/gate.json holds the latest verdict per profile label
# (A, B), each tagged with the fingerprint it was reviewed at, so a reader
# can tell whether a PASS still describes the code currently in the tree.
gate_record() {
  local slug=$1 label=$2 verdict=$3 fp=$4
  local f=$TASKS/$slug/gate.json tmp prev
  prev=$([ -f "$f" ] && cat "$f" || echo '{}')
  tmp=$(mktemp)
  if jq -n --argjson prev "$prev" \
    --arg label "$label" --arg verdict "$verdict" --arg fp "$fp" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$prev + {($label): {verdict: $verdict, fingerprint: $fp, at: $at}}' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    warn "could not record gate verdict for $slug/$label"
  fi
}

# Whether a task is ready to land: both A and B last passed, and both did so
# reviewing the exact code currently in the tree (same fingerprint on both,
# matching the tree's fingerprint right now). Anything else - one profile
# never run, a FAIL, or a fingerprint mismatch from code changing since -
# means "not established as ready" and is reported as such, not guessed at.
gate_ready() {
  local slug=$1 tree=$2 base=$3
  local f=$TASKS/$slug/gate.json cur a_v a_fp b_v b_fp
  [ -f "$f" ] || return 1
  cur=$(gate_fingerprint "$tree" "$base")
  a_v=$(jq -r '.A.verdict // empty' "$f" 2>/dev/null || true)
  a_fp=$(jq -r '.A.fingerprint // empty' "$f" 2>/dev/null || true)
  b_v=$(jq -r '.B.verdict // empty' "$f" 2>/dev/null || true)
  b_fp=$(jq -r '.B.fingerprint // empty' "$f" 2>/dev/null || true)
  [ "$a_v" = PASS ] && [ "$b_v" = PASS ] && [ "$a_fp" = "$cur" ] && [ "$b_fp" = "$cur" ]
}

git_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '-'; }
git_base() {
  local b
  b=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  [ -n "$b" ] || b=$(git_branch "$1")
  [ -n "$b" ] && [ "$b" != '-' ] || b=main
  printf '%s' "$b"
}

# Pre-accept the harness's trust dialog for a directory so a launch never stalls on it.
harness_trust() {
  local harness=$1 dir=$2 root cfg tmpj
  case $harness in
  claude)
    [ -f "$HOME/.claude.json" ] || return 0
    # Skip the read-modify-write when already trusted: every call used to
    # rewrite this shared file unconditionally, so N parallel gate/ask calls
    # raced on the same mv and one crashed with "File exists".
    jq -e --arg d "$dir" '.projects[$d].hasTrustDialogAccepted == true' \
      "$HOME/.claude.json" >/dev/null 2>&1 && return 0
    tmpj=$(mktemp)
    if jq --arg d "$dir" '.projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true})' \
         "$HOME/.claude.json" >"$tmpj" 2>/dev/null && [ -s "$tmpj" ]; then
      cp "$HOME/.claude.json" "$HOME/.claude.json.cap-bak" && mv "$tmpj" "$HOME/.claude.json"
    else
      rm -f "$tmpj"
      warn "could not trust $dir; the agent may stop on the trust dialog"
    fi
    ;;
  codex)
    # Codex resolves trust at the shared repo root, not per worktree.
    root=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
      root=$(dirname "$root") || root=$dir
    cfg=$HOME/.codex/config.toml
    if [ -f "$cfg" ] && ! grep -qF "[projects.\"$root\"]" "$cfg"; then
      cp "$cfg" "$cfg.cap-bak"
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$root" >>"$cfg"
    fi
    ;;
  esac
}

# Stacked tasks follow their parent's recorded branch tip.

STACK_MOVED=0
STACK_CONFLICT=""

# Store branch refs under state/restacks so --undo can restore them.
stack_snapshot_new() {
  mkdir -p "$CAP_HOME/state/restacks"
  printf '%s/state/restacks/%s-%s.snapshot' "$CAP_HOME" "$1" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# Save branch refs before rebase so --undo can restore them.
stack_snapshot_add() {
  git -C "$2" for-each-ref "refs/heads/$3" --format='%(objectname) %(refname)' >>"$1"
}

# Record a task.env field's current value before changing it, so --undo can
# put it back alongside the branch refs.
stack_snapshot_field() {
  printf 'FIELD %s %s %s\n' "$2" "$3" "$(task_field "$2" "$3")" >>"$1"
}

# Force-update a published branch after rebase.
stack_push() {
  git -C "$1" rev-parse --verify -q "origin/$2" >/dev/null || return 0
  git -C "$1" push --force-with-lease --force-if-includes origin "$2:$2" ||
    warn "could not push $2; its remote copy still holds the pre-rebase commits"
}

# Rebase a task from its recorded parent tip onto a new one.
# Run the rebase in the task worktree because Git rejects a branch checked out elsewhere.
# STACK_MOVED and STACK_CONFLICT report partial progress to the caller.
stack_sync_task() {
  local task=$1 new_tip=$2 snap=$3
  local tree branch old_tip

  tree=$(task_field "$task" CAP_TREE)
  branch=$(task_field "$task" CAP_BRANCH)
  old_tip=$(task_field "$task" CAP_PARENT_TIP)

  [ -d "$tree" ] || die "$task has no worktree at $tree"
  [ "$(git_dirty "$tree")" = 0 ] ||
    die "$task has uncommitted changes in $tree; commit or discard them first"

  if [ "$old_tip" != "$new_tip" ]; then
    stack_snapshot_add "$snap" "$tree" "$branch"

    if ! git -C "$tree" rebase --onto "$new_tip" "$old_tip"; then
      git -C "$tree" rebase --abort 2>/dev/null || true
      STACK_CONFLICT=$task
      warn "$task conflicts with its new base; its branch was left where it was"
      warn "resolve by hand: cd $tree && git rebase --onto $new_tip $old_tip"
      return 1
    fi

    stack_push "$tree" "$branch"
    STACK_MOVED=$((STACK_MOVED + 1))
  fi

  stack_snapshot_field "$snap" "$task" CAP_PARENT_TIP
  task_env_set "$task" CAP_PARENT_TIP "$new_tip"
}

stack_cascade() {
  local slug=$1 new_tip=$2 snap=$3
  local child tree

  for child in $(task_children "$slug"); do
    tree=$(task_field "$child" CAP_TREE)

    stack_sync_task "$child" "$new_tip" "$snap" || return 1
    stack_cascade "$child" "$(git -C "$tree" rev-parse HEAD)" "$snap" || return 1
  done
}

# After a parent lands, descendants inherit its base and PR target.
stack_cascade_landed() {
  local slug=$1 new_tip=$2 snap=$3
  local child tree up_base up_parent pr

  up_base=$(task_field "$slug" CAP_BASE)
  up_parent=$(task_field "$slug" CAP_PARENT)

  for child in $(task_children "$slug"); do
    tree=$(task_field "$child" CAP_TREE)

    stack_sync_task "$child" "$new_tip" "$snap" || return 1

    stack_snapshot_field "$snap" "$child" CAP_BASE
    task_env_set "$child" CAP_BASE "$up_base"
    stack_snapshot_field "$snap" "$child" CAP_PARENT
    task_env_set "$child" CAP_PARENT "$up_parent"

    pr=$(task_field "$child" CAP_PR)
    if [ -n "$pr" ]; then
      gh pr edit "$pr" --base "$up_base" >/dev/null ||
        warn "could not retarget $pr to $up_base; set its base by hand"
    fi

    stack_cascade "$child" "$(git -C "$tree" rev-parse HEAD)" "$snap" || return 1
  done
}

# Remove inherited model and session settings before starting an agent.
CAP_ENV_SCRUB=(-u ANTHROPIC_MODEL -u ANTHROPIC_SMALL_FAST_MODEL -u ANTHROPIC_DEFAULT_OPUS_MODEL
  -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u CLAUDE_CODE_SUBAGENT_MODEL
  -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT -u CODEX_SANDBOX)

# Point common package-manager caches at a shared location so a fresh
# worktree's install is not stuck starting cold, and a project's own relative
# cache config can't quietly defeat that sharing.
mkdir -p "$CAP_CACHE_ROOT"
CAP_CACHE_ENV=(
  NPM_CONFIG_CACHE="$CAP_CACHE_ROOT/npm"
  YARN_CACHE_FOLDER="$CAP_CACHE_ROOT/yarn"
  PIP_CACHE_DIR="$CAP_CACHE_ROOT/pip"
  CARGO_HOME="$CAP_CACHE_ROOT/cargo"
  GOMODCACHE="$CAP_CACHE_ROOT/go-mod"
  COMPOSER_CACHE_DIR="$CAP_CACHE_ROOT/composer"
)

ask_profile() {
  printf '%s\n' "$CAP_ASK_PROFILES" | awk -v p="$1" '$1==p {print $2, $3, ($4 == "" ? "-" : $4); found=1} END{exit !found}' ||
    die "unknown ask profile '$1' (see config/captain.conf)"
}

# --- dispatch sizing -------------------------------------------------------
#
# Captain never asks what plan the account is on. It reads the rate-limit
# windows the harness already reports to the status line, which bin/cap-statusline
# records for every session in the fleet, and it remembers which profiles the
# harness has actually rejected. Those two facts are enough to pick a model,
# and both are measurements rather than settings, so the same configuration
# behaves correctly on a plan Captain has never seen.

CAP_USAGE_DIR=$CAP_HOME/state/usage
CAP_BLOCK_DIR=$CAP_HOME/state/usage/blocked

usage_files() { compgen -G "$CAP_USAGE_DIR/*.json" >/dev/null 2>&1; }

# --- what the harness offers -----------------------------------------------
#
# Profile names a model and reasoning effort. Codex publishes both; Captain
# asks instead of guessing so invalid profiles fail early (cap models), not
# three minutes into a review. The catalog never carries tier assignments
# (which model is the right reviewer for critical work); that judgment stays
# in config/captain.conf.
#
# The claude harness publishes no equivalent, so its profiles go unchecked.
# Its aliases (opus, sonnet, haiku, fable) resolve at session start and the
# status line reports what they resolved to, which is discovery after the fact.

# One JSON-RPC round trip to the codex app-server. The server answers
# asynchronously and interleaves notifications, so this holds the request pipe
# open until the reply carrying the matching id arrives. Writing both requests
# and closing stdin does not work: the server sees EOF and exits before it has
# answered.
codex_rpc() {
  local method=$1 params=${2:-'{}'} d writer server rc=1 i
  command -v codex >/dev/null 2>&1 || return 1
  d=$(mktemp -d) || return 1
  if ! mkfifo "$d/in" 2>/dev/null; then
    rm -rf "$d"
    return 1
  fi
  {
    printf '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"captain","version":"1"}}}\n'
    printf '{"id":2,"method":"%s","params":%s}\n' "$method" "$params"
    # Become the sleep, so killing this pid closes the write end of the fifo.
    exec sleep 30
  } >"$d/in" 2>/dev/null &
  writer=$!
  timeout 30 codex app-server <"$d/in" >"$d/out" 2>/dev/null &
  server=$!
  for ((i = 0; i < 100; i++)); do
    if grep -q '"id":2' "$d/out" 2>/dev/null; then
      rc=0
      break
    fi
    if ! kill -0 "$server" 2>/dev/null; then break; fi
    sleep 0.05
  done
  kill "$writer" "$server" 2>/dev/null || true
  wait "$writer" "$server" 2>/dev/null || true
  if [ "$rc" = 0 ]; then grep -h '"id":2' "$d/out" | tail -1; fi
  rm -rf "$d"
  return "$rc"
}

# The result of one app-server method, cached on disk. Sizing is supposed to be
# free, so nothing here may cost a dispatch a network round trip it can avoid.
# A failure is cached too, as an empty file: a codex that is logged out or
# offline would otherwise charge every single dispatch a fresh timeout.
codex_cached() {
  local file=$1 ttl=$2 method=$3 params=${4:-'{}'} age out
  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 1
  file=$CAP_USAGE_DIR/$file
  if [ -f "$file" ]; then
    age=$(($(now) - $(stat -c %Y "$file" 2>/dev/null || echo 0)))
    if [ "$age" -lt "$ttl" ]; then
      [ -s "$file" ] || return 1
      cat "$file"
      return 0
    fi
  fi
  out=$(codex_rpc "$method" "$params" 2>/dev/null | jq -c '.result // empty' 2>/dev/null) || out=""
  if [ -z "$out" ] && [ -s "$file" ]; then
    # A catalog from yesterday is still the catalog. Keep it and stop asking
    # for one TTL rather than throwing away the only answer Captain has.
    touch "$file"
    cat "$file"
    return 0
  fi
  printf '%s' "$out" >"$file"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Every model this account can reach, as the harness reports it. Cached for a
# day: the list changes when OpenAI ships a model, not between dispatches.
codex_catalog() { codex_cached codex-models.json 86400 model/list '{"includeHidden":false}'; }

# Whether a profile names something the harness will accept. Prints what is
# wrong and returns 1 when it does not. Silent and successful when the profile
# is fine, when its harness publishes no catalog, and when the catalog cannot
# be read at all, because "Captain could not check" is not "the captain is
# wrong".
profile_check() {
  local profile=$1 harness model effort catalog problem
  read -r harness model effort <<<"$(ask_profile "$profile")"
  [ "$harness" = codex ] || return 0
  [ "$model" != '-' ] || return 0
  catalog=$(codex_catalog) || return 0
  problem=$(printf '%s' "$catalog" | jq -r --arg m "$model" --arg e "$effort" '
    (.data // []) as $all
    | ($all | map(select(.model == $m or .id == $m)) | first) as $found
    | if $found == null then
        "codex has no model \($m); it offers \($all | map(.model) | join(", "))"
      elif $e != "-" and (($found.supportedReasoningEfforts // []) | map(.reasoningEffort) | index($e)) == null then
        "\($m) does not accept effort \($e); it accepts \(($found.supportedReasoningEfforts // []) | map(.reasoningEffort) | join(", "))"
      else empty end
  ' 2>/dev/null) || return 0
  [ -n "$problem" ] || return 0
  printf '%s' "$problem"
  return 1
}

# The codex harness has no status line hook, so nothing records a reading for
# it as it runs. Two places have one anyway.
#
# The app-server answers account/rateLimits/read with the windows as they stand
# right now. That is the reading Captain wants, because the moment it most needs
# to know whether codex has room is the moment no codex session is running.
#
# Failing that, every turn appends a token_count event to the session's rollout,
# carrying the same two windows under snake_case names. It is a real reading but
# a retrospective one: it is exactly as old as the last codex turn.
#
# Both records also carry plan_type ("plus", "pro"). Captain does not read it.
# Knowing the percentage is measuring the account; knowing the plan is
# describing it, and a description is the thing that goes stale.
codex_rollout() {
  find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -newermt '-24 hours' \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# Non-empty when codex last reported that a window is exhausted. This is the
# codex equivalent of the claude "hit your session limit" banner, and unlike
# that banner it is a field rather than a sentence, so it needs no matching.
codex_limit_reached() {
  codex_rate_limits | jq -r '.rate_limit_reached_type // empty' 2>/dev/null || true
}

codex_rollout_limits() {
  local f
  f=$(codex_rollout)
  [ -n "$f" ] || return 1
  grep -h '"rate_limits"' "$f" 2>/dev/null | tail -1 |
    jq -e '.payload.rate_limits // empty' 2>/dev/null
}

# The live reading when the app-server answers, the rollout when it does not.
# The two spell the same fields differently, so the live one is renamed into the
# rollout's shape and every caller below stays written once. The source travels
# with the reading so cap budget can say which one a number came from.
codex_rate_limits() {
  local live
  if live=$(codex_cached codex-limits.json "${CAP_USAGE_TTL:-900}" account/rateLimits/read); then
    if printf '%s' "$live" | jq -e '
      .rateLimits
      | {primary: (if .primary then {used_percent: .primary.usedPercent,
                                     resets_at: .primary.resetsAt,
                                     window_minutes: .primary.windowDurationMins} else null end),
         secondary: (if .secondary then {used_percent: .secondary.usedPercent,
                                         resets_at: .secondary.resetsAt,
                                         window_minutes: .secondary.windowDurationMins} else null end),
         rate_limit_reached_type: .rateLimitReachedType,
         source: "app-server"}
    ' 2>/dev/null; then
      return 0
    fi
  fi
  codex_rollout_limits | jq -e '. + {source: "rollout"}' 2>/dev/null
}

# Measured utilization for one harness, as "<percent> <resets_at> <source>". The
# percent is the fullest window that harness reports, because the tightest
# window is the one that will stop the next dispatch.
#
# Readings are per harness on purpose. An Anthropic window says nothing about
# an OpenAI one, and sizing a codex rung against a claude meter would be the
# same mistake as hardcoding a model: a number that describes a different
# account.
#
# Prints "- - none" when nothing recent enough exists, which every caller reads
# as "no reason to hold back", never as "full". Refusing to work because the
# meter is unreadable would be worse than the problem the meter solves.
usage_read() {
  local harness=${1:-claude} cutoff out
  cutoff=$(($(now) - ${CAP_USAGE_TTL:-900}))

  if usage_files; then
    # five_hour/seven_day come from the single newest record, same as always.
    # spend_limit comes from whichever record within the same cutoff last
    # actually observed one, independently - a headless call's record never
    # carries one, so it must not shadow an interactive session's still-fresh
    # reading just for being newer overall.
    out=$(jq -rs --argjson cutoff "$cutoff" --arg h "$harness" '
      map(select((.at // 0) >= $cutoff and (.harness // "claude") == $h)) as $recent
      | if ($recent | length) == 0 then empty else
          ($recent | max_by(.at)) as $latest
          | (now) as $n
          | ([$recent[] | select(.spend_limit != null)] | if length == 0 then null
             else (max_by(.at) | .spend_limit) end) as $sl
          | [(if ($latest.five_hour.resets_at // 0) > $n then ($latest.five_hour.pct // 0) else 0 end),
             (if ($latest.seven_day.resets_at // 0) > $n then ($latest.seven_day.pct // 0) else 0 end),
             (if $sl == null then 0 else
                (($sl.resets_at // 0) as $sr | if $sr == 0 or $sr > $n then ($sl.pct // 0) else 0 end)
              end)] as $p
          | "\($p | max | floor) \($latest.five_hour.resets_at // 0) snapshot"
        end
    ' "$CAP_USAGE_DIR"/*.json 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  if [ "$harness" = codex ]; then
    # A window whose reset time has passed is not still full, it is empty. This
    # matters here and not for claude, where a status line rewrites the reading
    # every few seconds; a rollout reading can easily outlive its own window.
    out=$(codex_rate_limits | jq -r '
      (now) as $n
      | (if (.primary.resets_at // 0) > $n then (.primary.used_percent // 0) else 0 end) as $p
      | (if (.secondary.resets_at // 0) > $n then (.secondary.used_percent // 0) else 0 end) as $s
      | "\([$p, $s] | max | floor) \(.primary.resets_at // 0) \(.source // "rollout")"
    ' 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  # The claude harness also caches a usage reading in ~/.claude.json, but only
  # refreshes it now and then, so it is a fallback and carries a longer life.
  if [ "$harness" = claude ] && [ -f "$HOME/.claude.json" ]; then
    out=$(jq -r --argjson cutoff "$(($(now) - 21600))" '
      .cachedUsageUtilization
      | select(((.fetchedAtMs // 0) / 1000) >= $cutoff)
      | .utilization.limits // []
      | if length == 0 then empty else "\(map(.percent) | max | floor) 0 cache" end
    ' "$HOME/.claude.json" 2>/dev/null) || out=""
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi

  printf -- '- - none\n'
}

# A human breakdown of one harness's reading, for cap budget. Decisions use
# usage_read; this exists so a captain can see which window is the tight one.
usage_detail() {
  local harness=$1 src=$2
  case $harness:$src in
    claude:cache) printf 'from the harness cache in ~/.claude.json' ;;
    claude:*)
      usage_files || return 0
      jq -rs --arg h "$harness" '
        map(select((.harness // "claude") == $h))
        | if length == 0 then "" else
            (max_by(.at)
             | "5h \(.five_hour.pct // 0 | floor)%, 7d \(.seven_day.pct // 0 | floor)%, read \(now - .at | floor)s ago")
          end' "$CAP_USAGE_DIR"/*.json 2>/dev/null || true
      ;;
    codex:*)
      codex_rate_limits | jq -r '
        (if .source == "app-server" then "live from the codex app-server"
         else "from the newest codex rollout" end) as $src
        | "5h \(.primary.used_percent // 0 | floor)%, 7d \(.secondary.used_percent // 0 | floor)%, \($src)"
      ' 2>/dev/null || true
      ;;
  esac
}

# The rule for picking which of a result's modelUsage entries names the
# model actually asked for: the one whose canonicalModel/key names the
# profile's model, or the largest context window when nothing matches.
# usage_write and cap-ask's ctx_pct both interpolate this one definition, so
# a session with more than one model (a subagent adds its own entry) can
# never have the two disagree about which one is "the" model.
read -r -d '' CAP_MODEL_PICK_JQ <<'JQ' || true
def pick_model($model):
  (.modelUsage // {}) | to_entries as $entries
  | (if ($model // "") == "" or $model == "-" then null
     else ($entries | map(select((.value.canonicalModel // .key // "") | contains($model))) | .[0])
     end)
    // ($entries | max_by(.value.contextWindow // 0));
JQ

# Record a claude quota reading in the shape bin/cap-statusline writes in
# Python, so usage_read has a fresh number even for a session whose status
# line never rendered (that hook only fires for an interactive session).
# mise run check:usage-shape asserts the two writers agree on that shape.
usage_write() {
  local session=$1 dir=$2 rl_json=${3:-} result_json=${4:-} model=${5:-}
  [ -n "$session" ] || return 0

  # A rejection's own rate_limit_event doesn't always carry unifiedWindows
  # (its own rejection reason lives in api_error_status/terminal_reason
  # instead). Write nothing rather than let the // 0 defaults below publish
  # a fabricated 0% that usage_read's max_by(.at) would then prefer over any
  # real reading.
  jq -e '(.rate_limit_info.unifiedWindows.five_hour // .rate_limit_info.unifiedWindows.seven_day) != null' \
    <<<"${rl_json:-null}" >/dev/null 2>&1 || return 0

  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 0

  local model_id="" model_fallback="" display=""
  IFS=$'\t' read -r model_id model_fallback <<<"$(jq -r --arg model "$model" "$CAP_MODEL_PICK_JQ"'
    pick_model($model) as $mu | "\($mu.key // "")\t\($mu.value.canonicalModel // $mu.key // "")"
  ' <<<"${result_json:-null}" 2>/dev/null)" || true

  # Only an interactive status line learns a model's display name
  # (bin/cap-statusline, keyed by model.id); reuse its last recording for
  # this model id instead of restating the raw id. The "^claude-" exclusion
  # skips raw ids and this function's own past placeholder writes.
  if [ -n "$model_id" ]; then
    display=$(jq -rs --arg mid "$model_id" '
      map(select(.model_id == $mid and (.model // "") != "" and (((.model // "") | test("^claude-")) | not)))
      | sort_by(.at) | last | .model // empty
    ' "$CAP_USAGE_DIR"/*.json 2>/dev/null) || true
  fi

  # A headless call's rate_limit_event never carries a spend_limit field;
  # only bin/cap-statusline's interactive reading ever observes one. Write
  # null rather than carry an old reading forward under this call's own
  # fresh at - a carried value stopped aging out under CAP_USAGE_TTL, which
  # let a stale spend_limit outlive its own record indefinitely. usage_read
  # finds the newest record that actually observed one instead.
  jq -n --arg session "$session" --arg dir "$dir" --argjson at "$(now)" \
    --arg model_id "$model_id" --arg model_fallback "$model_fallback" \
    --argjson rl "${rl_json:-null}" --arg disp "$display" --argjson spend null '
    # Explicit half-away-from-zero, the formula bin/cap-statusline also uses
    # (math.floor(pct + 0.5)). mise run check:usage-shape asserts they agree.
    def pct_round: (. + 0.5) | floor;
    {at: $at, session_id: $session, harness: "claude",
     model_id: $model_id,
     model: (if $disp != "" then $disp else $model_fallback end),
     cwd: $dir, project_dir: $dir,
     five_hour: {pct: (($rl.rate_limit_info.unifiedWindows.five_hour.utilization // 0) * 100 | pct_round),
                 resets_at: ($rl.rate_limit_info.unifiedWindows.five_hour.resetsAt // 0)},
     seven_day: {pct: (($rl.rate_limit_info.unifiedWindows.seven_day.utilization // 0) * 100 | pct_round),
                 resets_at: ($rl.rate_limit_info.unifiedWindows.seven_day.resetsAt // 0)},
     spend_limit: $spend}' \
    >"$CAP_USAGE_DIR/$session.json.tmp" 2>/dev/null &&
    mv "$CAP_USAGE_DIR/$session.json.tmp" "$CAP_USAGE_DIR/$session.json"
}

# A profile the harness has rejected for a session limit is out of its tier
# until its window resets. This is the one signal that is never a guess: the
# account said no.
profile_block() {
  local p=$1 until=${2:-0}
  [ "$until" -gt "$(now)" ] 2>/dev/null || until=$(($(now) + ${CAP_BLOCK_SECS:-3600}))
  mkdir -p "$CAP_BLOCK_DIR"
  printf '%s\n' "$until" >"$CAP_BLOCK_DIR/$p"
}
profile_block_until() { cat "$CAP_BLOCK_DIR/$1" 2>/dev/null || printf '0'; }
profile_blocked() {
  local until
  until=$(profile_block_until "$1")
  if [ "$until" -gt "$(now)" ] 2>/dev/null; then
    return 0
  fi
  rm -f "$CAP_BLOCK_DIR/$1"
  return 1
}

# Sizing is a harness decision, so it reports to a file rather than to whoever
# is watching. A captain running cap spawn is an agent too: a line of routine
# "role crew -> sonnet" chatter on every dispatch spends its context to tell it
# something it did not ask for and cannot act on. cap budget reads this back
# when the answer needs explaining.
CAP_DISPATCH_LOG=$CAP_USAGE_DIR/dispatch.log

dispatch_log() {
  local caller=${0##*/}
  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$caller" "$1" "$2" "$3" "$4" >>"$CAP_DISPATCH_LOG" 2>/dev/null || return 0
  # Keep the tail, drop the history. Nobody audits a dispatch from last month.
  if [ "$(stat -c %s "$CAP_DISPATCH_LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
    tail -n 200 "$CAP_DISPATCH_LOG" >"$CAP_DISPATCH_LOG.tmp" 2>/dev/null &&
      mv "$CAP_DISPATCH_LOG.tmp" "$CAP_DISPATCH_LOG"
  fi
}

# What kind of thinking a role needs, and which profiles can supply it.
role_tier() {
  local var
  var=CAP_ROLE_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-}"
}

tier_peers() {
  local var
  var=CAP_TIER_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-}"
}

tier_admit() {
  local var
  var=CAP_ADMIT_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-100}"
}

# Pick a profile from one tier. Peers within a tier are interchangeable in
# capability and live on different accounts, so a full window moves work
# sideways rather than downwards. Quota chooses which account runs the work and
# whether it starts at all; it never chooses how capable the agent is.
#
# `avoid` lets a caller that needs two independent opinions ask for a second.
tier_profile() {
  local tier=$1 role=$2 avoid=${3:-} peers profile admit pct pair harness
  peers=$(tier_peers "$tier")
  [ -n "$peers" ] || die "tier '$tier' lists no profiles (see config/captain.conf)"
  admit=$(tier_admit "$tier")

  for profile in $peers; do
    if [ "$profile" = "$avoid" ]; then
      continue
    fi
    if profile_blocked "$profile"; then
      continue
    fi
    # A peer naming a profile that does not exist is a typo in the config, not
    # a dispatch. Skipping it silently would size it against a harness of "",
    # which measures nothing and therefore holds nothing back.
    if ! pair=$(ask_profile "$profile" 2>/dev/null); then
      warn "tier '$tier' names unknown profile '$profile'; skipping it"
      continue
    fi
    read -r harness _ <<<"$pair"
    read -r pct _ _ <<<"$(usage_read "$harness")"
    if [ "$pct" != '-' ] && [ "$pct" -gt "$admit" ]; then
      continue
    fi
    dispatch_log "$role" "$profile" "$harness" "$pct"
    printf '%s' "$profile"
    return 0
  done
  return 1
}

role_profile() {
  local role=$1 tier
  tier=$(role_tier "$role")
  [ -n "$tier" ] || die "unknown dispatch role '$role' (see config/captain.conf)"
  tier_profile "$tier" "$role" "${2:-}"
}

role_profile_or_die() {
  local role=$1 tier=${2:-} p peers profile pair harness pct resets src until soonest=0 msg detail=""
  [ -n "$tier" ] || tier=$(role_tier "$role")
  [ -n "$tier" ] || die "unknown dispatch role '$role' (see config/captain.conf)"
  if p=$(tier_profile "$tier" "$role"); then
    printf '%s' "$p"
    return 0
  fi

  peers=$(tier_peers "$tier")
  for profile in $peers; do
    if profile_blocked "$profile"; then
      until=$(profile_block_until "$profile")
      detail="$detail $profile(rate limited until $(date -d "@$until" '+%H:%M'))"
      if [ "$soonest" = 0 ] || [ "$until" -lt "$soonest" ]; then
        soonest=$until
      fi
      continue
    fi
    pair=$(ask_profile "$profile" 2>/dev/null) || continue
    read -r harness _ <<<"$pair"
    read -r pct resets src <<<"$(usage_read "$harness")"
    detail="$detail $profile($harness at $pct%, source $src)"
    if [ "$resets" -gt "$(now)" ] 2>/dev/null; then
      if [ "$soonest" = 0 ] || [ "$resets" -lt "$soonest" ]; then
        soonest=$resets
      fi
    fi
  done

  # Say no rather than quietly running a smaller model. Work of this tier needs
  # a model of this tier; a cheaper one produces a session that has to be found
  # and undone, which costs more than the wait.
  msg="no $tier profile can take role '$role' right now:$detail"
  if [ "$soonest" -gt "$(now)" ] 2>/dev/null; then
    msg="$msg. Earliest capacity at $(date -d "@$soonest" '+%H:%M')"
  fi
  die "$msg. run: cap budget"
}
