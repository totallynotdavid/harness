# bin/lib.sh - shared helpers for cap commands.

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

# Run a command in a pane via a temp script. herdr pane run types its argument
# into the pane's cooked-mode pty; a prompt of a few KB overruns the tty's
# line-length limit and truncates mid-quote, hanging the shell. A short
# "bash <script>" line never does.
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

# Send text without pressing Enter.
pane_send() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane send-text "$p" "$2" >/dev/null 2>&1
}
pane_enter() {
  local p
  p=$(task_pane "$1")
  [ -n "$p" ] && herdr pane send-keys "$p" enter >/dev/null 2>&1
}

# herdr's own reported status ("working"/"idle"/"unknown"), not a guess from
# output staleness. The authoritative answer to "did a turn actually start."
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

# A fingerprint of exactly what a gate call reviews: the full diff against
# base plus any uncommitted change. Two gate calls with the same fingerprint
# reviewed the identical code, regardless of how many commits or stash
# round-trips happened in between.
gate_fingerprint() { git -C "$1" diff "$2" 2>/dev/null | sha256sum | cut -d' ' -f1; }

# The exact-line GATE: PASS / GATE: FAIL verdict from a gate report, ignoring
# any earlier match against the echoed prompt text itself (the prompt
# contains the literal substrings "GATE: PASS" and "GATE: FAIL" inside the
# instruction sentence, which is not a verdict).
gate_verdict() {
  [ -f "$1" ] || { printf 'UNKNOWN'; return; }
  # Strip each line's leading non-letter clutter first: codex pads with plain
  # spaces, claude prefixes a "* " bullet marker. Only then does the line
  # have to be exactly "GATE: PASS"/"GATE: FAIL" (plus trailing whitespace)
  # to count - never a substring match, which is what the echoed prompt
  # sentence ("...exactly: GATE: PASS or GATE: FAIL.") would give.
  tail -15 "$1" | sed -E 's/^[^A-Za-z]*//' |
    grep -E '^GATE: (PASS|FAIL)[[:space:]]*$' | tail -1 |
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
  printf '%s\n' "$CAP_ASK_PROFILES" | awk -v p="$1" '$1==p {print $2, $3; found=1} END{exit !found}' ||
    die "unknown ask profile '$1' (see config/captain.conf)"
}
