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

# Send text without pressing Enter. Chunked: herdr pane send-text types
# straight into the pane with no backpressure, and a target TUI's own input
# handling can't always keep up. Confirmed by hand against a live codex
# instance: a single send-text call of a normal multi-paragraph message
# (well under any documented size limit - 1785 chars) silently dropped
# everything after roughly the first 1000, mid-word, with no error from
# herdr or codex. Sending in small pieces with a short pause between each
# reproduced the identical message intact every time; a single un-chunked
# call reproduced the drop every time. Chunk size and pause are empirical
# margin below where drops were observed, not a documented limit from herdr.
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
#
# Untracked files are part of that, and used to be missing. A task whose
# deliverable is new files carries almost no tracked diff: local-env added a
# 17-file .devstack/ directory against 983 bytes of `git diff`. A diff-only
# fingerprint stayed constant while the actual work changed underneath it, so
# gate_ready kept reporting a stale PASS as fresh and cap-crew showed `ready`
# for a review that never saw the deliverable.
gate_fingerprint() {
  local tree=$1 base=$2 f
  {
    git -C "$tree" diff "$base" 2>/dev/null || true
    # Hash each path as well as its bytes, so a rename is a new fingerprint.
    while IFS= read -r -d '' f; do
      printf '=== %s\n' "$f"
      cat -- "$tree/$f" 2>/dev/null || true
    done < <(git -C "$tree" ls-files --others --exclude-standard -z 2>/dev/null | sort -z)
  } | sha256sum | cut -d' ' -f1
}

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

# The codex harness has no status line hook, so nothing records a reading for
# it as it runs. It does write one to disk anyway: every turn appends a
# token_count event to the session's rollout, and that event carries the same
# two windows the claude harness reports, under different names. primary is the
# five-hour window, secondary the weekly one.
#
# The same record also carries plan_type ("plus", "pro"). Captain does not read
# it. Knowing the percentage is measuring the account; knowing the plan is
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

codex_rate_limits() {
  local f
  f=$(codex_rollout)
  [ -n "$f" ] || return 1
  grep -h '"rate_limits"' "$f" 2>/dev/null | tail -1 |
    jq -e '.payload.rate_limits // empty' 2>/dev/null
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
    out=$(jq -rs --argjson cutoff "$cutoff" --arg h "$harness" '
      map(select((.at // 0) >= $cutoff and (.harness // "claude") == $h))
      | if length == 0 then empty else
          (max_by(.at)
           | (now) as $n
           | [(if (.five_hour.resets_at // 0) > $n then (.five_hour.pct // 0) else 0 end),
              (if (.seven_day.resets_at // 0) > $n then (.seven_day.pct // 0) else 0 end),
              (.spend_limit.pct // 0)] as $p
           | "\($p | max | floor) \(.five_hour.resets_at // 0) snapshot")
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
      | "\([$p, $s] | max | floor) \(.primary.resets_at // 0) rollout"
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
        "5h \(.primary.used_percent // 0 | floor)%, 7d \(.secondary.used_percent // 0 | floor)%, from the newest codex rollout"
      ' 2>/dev/null || true
      ;;
  esac
}

# The model the captain's own session is running, from the status line
# recording made in this repository. Only this repository: a haiku crewmate's
# reading must not cap what the captain can dispatch.
captain_model() { captain_field model_id; }

# The harness that model runs under. The ceiling only bounds rungs on this same
# harness, because a rank comparison across harnesses is meaningless: "opus is
# stronger than sonnet" is a fact about one vendor's line-up, not a currency.
captain_harness() { captain_field harness; }

captain_field() {
  usage_files || return 0
  jq -rs --arg home "$CAP_HOME" --arg f "$1" '
    map(select((.cwd // "") == $home or (.project_dir // "") == $home))
    | if length == 0 then "" else (max_by(.at) | .[$f] // "") end
  ' "$CAP_USAGE_DIR"/*.json 2>/dev/null || true
}

profile_rank() {
  printf '%s\n' "${CAP_PROFILE_RANK:-}" | tr ' ' '\n' |
    awk -F: -v p="$1" '$1==p {print $2; found=1} END{exit !found}' || printf '0'
}

# The strongest rank a dispatch may use right now.
ceiling_rank() {
  local m
  case ${CAP_CEILING:-auto} in
    none) printf '99'; return 0 ;;
    auto) ;;
    *) profile_rank "$CAP_CEILING"; return 0 ;;
  esac
  m=$(captain_model)
  case $m in
    *fable*) profile_rank fable ;;
    *opus*) profile_rank opus ;;
    *sonnet*) profile_rank sonnet ;;
    *haiku*) profile_rank haiku ;;
    *) printf '99' ;;
  esac
}

# A profile the harness has rejected for a session limit is out of every ladder
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

role_ladder() {
  local var
  var=CAP_LADDER_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-}"
}

# Resolve a role to the profile it should dispatch to right now. Walks the
# ladder strongest first and takes the first rung that the account has not
# rejected, that is not stronger than the captain's own session, and whose
# utilization ceiling the current reading is still under.
# The optional second argument is a profile to skip, so a caller that needs two
# genuinely independent opinions can ask for a second one.
role_profile() {
  local role=$1 avoid=${2:-} ladder rung profile top pct ceil rank harness home_harness pair
  ladder=$(role_ladder "$role")
  [ -n "$ladder" ] || die "unknown dispatch role '$role' (see config/captain.conf)"

  ceil=$(ceiling_rank)
  home_harness=$(captain_harness)

  for rung in $ladder; do
    profile=${rung%%:*}
    top=${rung##*:}
    if [ "$profile" = "$avoid" ]; then
      continue
    fi
    if profile_blocked "$profile"; then
      continue
    fi
    # A rung naming a profile that does not exist is a typo in the config, not
    # a dispatch. Skipping it silently would size the ladder against a harness
    # of "", which measures nothing and therefore holds nothing back.
    if ! pair=$(ask_profile "$profile" 2>/dev/null); then
      warn "ladder for role '$role' names unknown profile '$profile'; skipping it"
      continue
    fi
    read -r harness _ <<<"$pair"
    if [ "$harness" = "$home_harness" ]; then
      rank=$(profile_rank "$profile")
      if [ "$rank" != 0 ] && [ "$rank" -gt "$ceil" ]; then
        continue
      fi
    fi
    read -r pct _ _ <<<"$(usage_read "$harness")"
    if [ "$pct" != '-' ] && [ "$pct" -gt "$top" ]; then
      continue
    fi
    printf '%s' "$profile"
    return 0
  done
  return 1
}

# The strongest rung of a ladder, ignoring utilization and the ceiling. This is
# what an explicit captain override means: spend it. A blocked profile is still
# skipped, because a blocked profile cannot run at all.
role_top() {
  local role=$1 ladder rung profile
  ladder=$(role_ladder "$role")
  [ -n "$ladder" ] || die "unknown dispatch role '$role' (see config/captain.conf)"
  for rung in $ladder; do
    profile=${rung%%:*}
    if profile_blocked "$profile"; then
      continue
    fi
    printf '%s' "$profile"
    return 0
  done
  return 1
}

# Same, but explains itself instead of returning empty. A dispatch that cannot
# be sized is a dispatch that must not happen: starting the last rung anyway
# spends the remainder of the window on a session that will die part-way.
# When the harness rejects a call for a session limit, believe the reset time it
# reports. The status line recording carries an exact epoch; the rejection
# banner carries only a human time like "resets 11pm (UTC)". Zero means neither
# was readable, and profile_block falls back to its own window.
limit_reset_epoch() {
  local harness=${1:-claude} human=${2:-} t
  t=$(usage_read "$harness" | awk '{print $2}')
  if [ "$t" != '-' ] && [ "${t:-0}" -gt "$(now)" ] 2>/dev/null; then
    printf '%s' "$t"
    return 0
  fi
  human=${human#resets }
  human=${human%%(UTC)*}
  if [ -n "$human" ] && t=$(date -u -d "$human" +%s 2>/dev/null); then
    [ "$t" -gt "$(now)" ] || t=$((t + 86400))
    printf '%s' "$t"
    return 0
  fi
  printf '0'
}

role_profile_or_die() {
  local role=$1 p pct resets src rung profile until blocked="" soonest=0 msg ladder harness
  if p=$(role_profile "$role"); then
    printf '%s' "$p"
    return 0
  fi

  # Report the reading for the ladder's own harness, not some other account's.
  ladder=$(role_ladder "$role")
  read -r harness _ <<<"$(ask_profile "${ladder%%:*}" 2>/dev/null || printf 'claude -')"
  read -r pct resets src <<<"$(usage_read "$harness")"
  [ "$pct" != '-' ] || pct=unmeasured
  for rung in $ladder; do
    profile=${rung%%:*}
    if profile_blocked "$profile"; then
      blocked="$blocked $profile"
      until=$(profile_block_until "$profile")
      if [ "$soonest" = 0 ] || [ "$until" -lt "$soonest" ]; then
        soonest=$until
      fi
    fi
  done

  msg="no profile is dispatchable for role '$role' at $harness utilization $pct (source $src)"
  [ -z "$blocked" ] ||
    msg="$msg; rate limited:$blocked, first back at $(date -d "@$soonest" '+%H:%M')"
  if [ -z "$blocked" ] && [ "$resets" -gt "$(now)" ] 2>/dev/null; then
    msg="$msg; the window resets at $(date -d "@$resets" '+%H:%M')"
  fi
  die "$msg. run: cap budget"
}
