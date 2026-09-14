# This module is sourced by bin/lib.sh. Keep its public helpers stable.
# shellcheck shell=bash
# shellcheck disable=SC2034

git_dirty() { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }

# Like git_dirty, but ignores untracked files - for a checkout several
# sessions share with no locking, where a stray untracked file must not
# block another session's land.
git_dirty_tracked() { git -C "$1" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' '; }

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

# Fingerprint of exactly what a review from $from covers: its diff plus
# untracked files. Same fingerprint means identical code reviewed,
# independent of commits or stash round-trips. Untracked files must be
# included, since a diff alone says nothing about a new file the
# deliverable adds. $from can be a merge-base (a full-branch review) or a
# later commit (an incremental one); the caller resolves which.
gate_fingerprint_from() {
  local tree=$1 from=$2 f pid rc
  # A process substitution's own failure is invisible to the `while read`
  # loop consuming it: zero iterations reads exactly like no untracked
  # files, not like ls-files failing. set +e/-e brackets just this pipeline
  # so pipefail's status reaches the explicit die below instead of
  # aborting the function before it can say what went wrong.
  set +e
  {
    git -C "$tree" diff "$from" 2>/dev/null || true
    # Hash each path as well as its bytes, so a rename is a new fingerprint.
    while IFS= read -r -d '' f; do
      printf '=== %s\n' "$f"
      cat -- "$tree/$f" 2>/dev/null || true
    done < <(git -C "$tree" ls-files --others --exclude-standard -z 2>/dev/null | sort -z)
    pid=$!
    wait "$pid" || exit 1
  } | sha256sum | cut -d' ' -f1
  rc=$?
  set -e
  [ "$rc" = 0 ] || die "gate_fingerprint_from: could not list untracked files in $tree"
}

# Fingerprint of a full-branch review: everything since this branch left base.
gate_fingerprint() {
  local tree=$1 base=$2
  base=$(diff_base "$tree" "$base")
  gate_fingerprint_from "$tree" "$base"
}

# Files that a reviewer would see from a range, including new untracked files.
# An empty result means the branch's content is already in its base even when
# its commit graph still contains commits.
reviewable_files() {
  local tree=$1 from=$2 tracked untracked
  tracked=$(git -C "$tree" diff --name-only "$from") || return 1
  untracked=$(git -C "$tree" ls-files --others --exclude-standard) || return 1
  printf '%s\n%s\n' "$tracked" "$untracked" | sed '/^$/d' | sort -u
}

# A task's round is how many times its agent has reported done. A pipeline
# step counts only for the round it ran in, so an agent sent back to fix
# something makes every step after it due again.
task_round() {
  local n
  n=$(grep -c '^done:' "$TASKS/$1/status.log" 2>/dev/null) || true
  printf '%s' "${n:-0}"
}

# Record that a pipeline step ran for the task's current round, and what it
# came to. cap step reads this back; nothing else decides a step happened.
step_record() {
  local slug=$1 step=$2 result=$3 f=$TASKS/$1/steps.json tmp prev
  prev=$([ -f "$f" ] && cat "$f" || echo '{}')
  tmp=$(mktemp)
  if jq -n --argjson prev "$prev" --arg step "$step" --arg result "$result" \
    --argjson round "$(task_round "$slug")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$prev + {($step): {round: $round, result: $result, at: $at}}' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    warn "could not record step $step for $slug"
  fi
}

# Whether a step ran for the task's current round.
step_ran() {
  local slug=$1 step=$2 f=$TASKS/$1/steps.json
  [ -f "$f" ] || return 1
  [ "$(jq -r --arg s "$step" '.[$s].round // -1' "$f" 2>/dev/null)" = "$(task_round "$slug")" ]
}

# Record one profile's verdict for a task at the fingerprint it reviewed.
# state/tasks/<slug>/gate.json holds the latest verdict per profile label
# (A, B), each tagged with the fingerprint it was reviewed at, so a reader
# can tell whether a PASS still describes the code currently in the tree.
# $commit is HEAD at review time, so the next incremental round for this
# profile knows where its last review left off. $since is where that review's
# diff started, the range $fp was taken over.
gate_record() {
  local slug=$1 label=$2 verdict=$3 fp=$4 commit=$5 since=$6
  local f=$TASKS/$slug/gate.json tmp prev
  prev=$([ -f "$f" ] && cat "$f" || echo '{}')
  tmp=$(mktemp)
  if jq -n --argjson prev "$prev" \
    --arg label "$label" --arg verdict "$verdict" --arg fp "$fp" --arg commit "$commit" --arg since "$since" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$prev + {($label): {verdict: $verdict, fingerprint: $fp, commit: $commit, since: $since, at: $at}}' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    warn "could not record gate verdict for $slug/$label"
  fi
}

gate_passes_fingerprint() {
  local slug=$1 label=$2 fp=$3 f=$TASKS/$1/gate.json
  [ -f "$f" ] || return 1
  jq -e --arg l "$label" --arg fp "$fp" \
    '.[$l].verdict == "PASS" and .[$l].fingerprint == $fp' "$f" >/dev/null 2>&1
}

# The commit a profile's review last covered, so a plain (non-full) round
# can review only what changed since. Empty when the profile never ran.
gate_last_commit() {
  local slug=$1 label=$2
  local f=$TASKS/$slug/gate.json
  [ -f "$f" ] || return 0
  jq -r --arg l "$label" '.[$l].commit // empty' "$f" 2>/dev/null || true
}

# Where a plain (non-full) round should review from: $label's last
# commit, narrowed to only when that commit is still a trustworthy
# checkpoint. Falls back to the full range otherwise, or prints nothing
# when nothing has changed since - a clean tree at that same commit has no
# new content to review at all.
gate_review_since() {
  local slug=$1 label=$2 tree=$3 base=$4
  local full since verdict head mb_now mb_then reviewed_since reviewed_fp
  full=$(diff_base "$tree" "$base")

  since=$(gate_last_commit "$slug" "$label")
  [ -n "$since" ] || { printf '%s' "$full"; return; }
  git -C "$tree" cat-file -e "$since" 2>/dev/null || { printf '%s' "$full"; return; }
  git -C "$tree" merge-base --is-ancestor "$since" HEAD 2>/dev/null || { printf '%s' "$full"; return; }

  # A FAIL is not a checkpoint to increment from, and syncing $base into
  # this branch moves its fork point, which would otherwise pull $base's
  # own commits into the diff as if this branch had written them.
  verdict=$(jq -r --arg l "$label" '.[$l].verdict // empty' "$TASKS/$slug/gate.json" 2>/dev/null || true)
  [ "$verdict" = PASS ] || { printf '%s' "$full"; return; }
  mb_now=$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null || true)
  mb_then=$(git -C "$tree" merge-base "$base" "$since" 2>/dev/null || true)
  [ "$mb_now" = "$mb_then" ] || { printf '%s' "$full"; return; }

  head=$(git -C "$tree" rev-parse HEAD)
  if [ "$since" = "$head" ]; then
    # The last PASS ended at this commit. A tree still exactly what it
    # reviewed, fingerprinted over the range that review diffed, has nothing
    # new: printing nothing keeps that verdict. Otherwise a dirty tree has its
    # uncommitted changes to review from here, and a clean one, whose PASS saw
    # changes since discarded, gets the full range.
    reviewed_since=$(jq -r --arg l "$label" '.[$l].since // empty' "$TASKS/$slug/gate.json" 2>/dev/null || true)
    reviewed_fp=$(jq -r --arg l "$label" '.[$l].fingerprint // empty' "$TASKS/$slug/gate.json" 2>/dev/null || true)
    if [ -n "$reviewed_since" ] && git -C "$tree" cat-file -e "$reviewed_since" 2>/dev/null &&
      [ "$reviewed_fp" = "$(gate_fingerprint_from "$tree" "$reviewed_since")" ]; then
      return
    fi
    if [ "$(git_dirty "$tree")" != 0 ]; then
      printf '%s' "$since"
    else
      printf '%s' "$full"
    fi
    return
  fi

  printf '%s' "$since"
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
  a_v=$(jq -r '.A.verdict // empty' "$f" 2>/dev/null || true)
  b_v=$(jq -r '.B.verdict // empty' "$f" 2>/dev/null || true)
  # Cheap file reads first: neither verdict can be PASS without both A and B
  # having run, so a task missing either is settled before gate_fingerprint's
  # git diff and untracked-file scan is worth paying for.
  [ "$a_v" = PASS ] && [ "$b_v" = PASS ] || return 1
  [ -n "$(reviewable_files "$tree" "$(diff_base "$tree" "$base")")" ] || return 1
  a_fp=$(jq -r '.A.fingerprint // empty' "$f" 2>/dev/null || true)
  b_fp=$(jq -r '.B.fingerprint // empty' "$f" 2>/dev/null || true)
  cur=$(gate_fingerprint "$tree" "$base")
  [ "$a_fp" = "$cur" ] && [ "$b_fp" = "$cur" ]
}

# Whether a gate already failed the exact code in the tree: a FAIL recorded
# at the tree's current full-branch fingerprint. Reviewing that code again
# would pay for the same findings twice.
gate_failed_here() {
  local slug=$1 tree=$2 base=$3 f=$TASKS/$1/gate.json cur
  [ -f "$f" ] || return 1
  jq -e '[.A, .B] | map(select(. != null and .verdict == "FAIL")) | length > 0' "$f" >/dev/null 2>&1 || return 1
  cur=$(gate_fingerprint "$tree" "$base")
  jq -e --arg fp "$cur" '[.A, .B] | map(select(. != null and .verdict == "FAIL" and .fingerprint == $fp)) | length > 0' "$f" >/dev/null 2>&1
}

# rules/commits.md forbids crediting an AI, not a Co-Authored-By trailer as
# such - a cherry-picked upstream commit or a human pair credit is not this.
# Matches a session-link trailer, a generated-with byline, or a Co-Authored-By
# naming a known model or a vendor noreply address. One pattern, read by
# both cap-commit (strips it) and cap-land (refuses on it).
AI_TRAILER_RE='^(claude|codex)-session:|generated with \[(claude code|codex)\]|^co-authored-by:[[:space:]]*(claude|codex|chatgpt|gpt)\b|^co-authored-by:.*<noreply@(anthropic|openai)\.com>'

# cap-commit and cap-land only see a task branch. A captain session editing
# CLAUDE.md or config/captain.conf commits straight to the hub with plain
# `git commit`, a path neither of them touches, and a harness's own commit
# template can carry AI_TRAILER_RE's lines onto that commit with nothing
# to strip them. A commit-msg hook fires on that path too and git hooks
# live in the git dir every worktree of one repo shares, so installing it
# once from any of them covers the hub and every task worktree alike.
# Idempotent and cheap enough to call from every cap command: the common
# case is one stat plus a grep, and a failure (no git dir, no write
# access) is swallowed by the caller rather than breaking the command.
git_ensure_attribution_hook() {
  local tree=$1 gitdir hook
  gitdir=$(git -C "$tree" rev-parse --git-common-dir 2>/dev/null) || return 0
  case $gitdir in /*) ;; *) gitdir=$tree/$gitdir ;; esac
  hook=$gitdir/hooks/commit-msg
  [ -f "$hook" ] && grep -qF "$AI_TRAILER_RE" "$hook" 2>/dev/null && return 0
  mkdir -p "$gitdir/hooks" || return 0
  cat >"$hook" <<HOOK || return 0
#!/usr/bin/env bash
# Installed by git_ensure_attribution_hook (bin/lib.sh). rules/commits.md's
# no-AI-attribution rule, applied to the message before the commit is
# written rather than left for someone to remember or a later pass to
# strip. Silently drops matching lines; refuses only if nothing is left.
msg_file=\$1
stripped=\$(grep -viE '$AI_TRAILER_RE' "\$msg_file") || true
if [ -z "\$(printf '%s' "\$stripped" | tr -d '[:space:]')" ]; then
  printf 'commit-msg: message is nothing but AI attribution; write a real one\n' >&2
  exit 1
fi
printf '%s\n' "\$stripped" >"\$msg_file"
HOOK
  chmod +x "$hook" 2>/dev/null || true
}

# Every AI-credited line in tree $1's $2..HEAD range, one per output line,
# prefixed with the short hash of the commit it is in. A plain
# `git log --format='commit %h:%n%B' | grep -in` cannot do this: grep prints
# only matching lines, so the marker line is dropped along with everything
# that did not match.
ai_trailer_report() {
  local tree=$1 base=$2 c hashes
  # A process substitution's own failure (an invalid range, git missing)
  # is invisible to the while loop that reads it - zero iterations reads
  # exactly like a clean range with nothing to flag. Read it into a
  # variable first so its exit status is this function's own.
  hashes=$(git -C "$tree" log --format=%h "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check attribution"
  [ -z "$hashes" ] && return 0
  while IFS= read -r c; do
    # grep exits 1 on the (usual) commit with nothing to flag; under set -e,
    # inherited from lib.sh, that would abort this loop at the first clean
    # commit instead of finishing the range.
    git -C "$tree" log -1 --format='%B' "$c" |
      { grep -inE "$AI_TRAILER_RE" || true; } | sed "s/^/$c: /"
  done <<<"$hashes"
}

# Every commit message rule that cap-commit can check before it returns. Keep
# this beside the landing check so a branch cannot pass one command and fail
# the other for the same message.
commit_rule_report() {
  local tree=$1 base=$2 hashes c short subject message second ai
  hashes=$(git -C "$tree" log --format=%H "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check commit messages"

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    short=$(git -C "$tree" log -1 --format=%h "$c")
    subject=$(git -C "$tree" log -1 --format=%s "$c")
    message=$(git -C "$tree" log -1 --format=%B "$c")
    second=$(printf '%s\n' "$message" | sed -n '2p')

    if [ -z "$subject" ]; then
      printf '%s: summary is empty\n' "$short"
    elif [ "${#subject}" -gt 50 ]; then
      printf '%s: summary is %s characters: %s\n' "$short" "${#subject}" "$subject"
    fi
    case $subject in
    feat:* | feat\(*\):* | fix:* | fix\(*\):*)
      printf '%s: summary uses a conventional-commit prefix: %s\n' "$short" "$subject"
      ;;
    esac
    case $subject in
    *.) printf '%s: summary ends with a period: %s\n' "$short" "$subject" ;;
    esac
    [ -z "$second" ] ||
      printf '%s: the second line must be blank\n' "$short"
  done <<<"$hashes"

  ai=$(ai_trailer_report "$tree" "$base")
  [ -z "$ai" ] || printf '%s\n' "$ai"
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
    # Avoid rewriting the shared trust file when the directory is already
    # trusted. Parallel launches should not contend on an unnecessary write.
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
