# shellcheck shell=bash

git_dirty() { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }

# Like git_dirty, but ignores untracked files - for a checkout several
# sessions share with no locking, where a stray untracked file must not
# block another session's land.
git_dirty_tracked() { git -C "$1" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' '; }

# Merge the current base into a worktree before review. A merge conflict falls
# back to the stale diff. A stash reapply conflict returns 1 with the worktree
# left for the task's agent to resolve.
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
    warn "$tree: $base moved and merging it conflicts; gating the stale diff as-is (see docs/operations.md)"
    return 0
  fi

  if [ "$stashed" = 1 ] && ! git -C "$tree" stash pop >/dev/null 2>&1; then
    warn "$tree: merged $base, but reapplying stashed work conflicts. The worktree is now mid-conflict; not gating this round. Resolve it (see docs/operations.md), ideally by asking the task's own agent to run 'git stash pop' and fix the conflict itself."
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

# Store a profile's verdict with the fingerprint and range it reviewed.
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
  [ -n "$since" ] || {
    printf '%s' "$full"
    return
  }
  git -C "$tree" cat-file -e "$since" 2>/dev/null || {
    printf '%s' "$full"
    return
  }
  git -C "$tree" merge-base --is-ancestor "$since" HEAD 2>/dev/null || {
    printf '%s' "$full"
    return
  }

  # A FAIL is not a checkpoint to increment from, and syncing $base into
  # this branch moves its fork point, which would otherwise pull $base's
  # own commits into the diff as if this branch had written them.
  verdict=$(jq -r --arg l "$label" '.[$l].verdict // empty' "$TASKS/$slug/gate.json" 2>/dev/null || true)
  [ "$verdict" = PASS ] || {
    printf '%s' "$full"
    return
  }
  mb_now=$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null || true)
  mb_then=$(git -C "$tree" merge-base "$base" "$since" 2>/dev/null || true)
  [ "$mb_now" = "$mb_then" ] || {
    printf '%s' "$full"
    return
  }

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

# A task is ready only when both profiles passed the current fingerprint.
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

# Match generated session links, bylines, and model or vendor co-authors.
AI_TRAILER_RE='^(claude|codex)-session:|generated with \[(claude code|codex)\]|^co-authored-by:[[:space:]]*(claude|codex|chatgpt|gpt)\b|^co-authored-by:.*<noreply@(anthropic|openai)\.com>'

# Install the attribution filter in the shared Git directory. All worktrees
# then use the same hook, including direct commits in the Captain checkout.
git_ensure_attribution_hook() {
  local tree=$1 gitdir hook
  gitdir=$(git -C "$tree" rev-parse --git-common-dir 2>/dev/null) || return 0
  case $gitdir in /*) ;; *) gitdir=$tree/$gitdir ;; esac
  hook=$gitdir/hooks/commit-msg
  [ -f "$hook" ] && grep -qF "$AI_TRAILER_RE" "$hook" 2>/dev/null && return 0
  mkdir -p "$gitdir/hooks" || return 0
  cat >"$hook" <<HOOK || return 0
#!/usr/bin/env bash
# Installed by git_ensure_attribution_hook (bin/lib.sh). Captain removes
# generated attribution before a message reaches history. Silently drops
# matching lines; refuses only if nothing is left.
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

commit_subject_report() {
  local label=$1 subject=$2 action
  local conventional_re='^(revert:[[:space:]])?(feat|fix|docs|style|refactor|perf|test|build|ci|chore)(\([^)]*\))?!?:[[:space:]]'

  [ -n "$subject" ] || printf '%s: summary is empty\n' "$label"

  case $subject in
  *$'\n'*) printf '%s: summary must be one line\n' "$label" ;;
  [!a-z]*) printf '%s: summary must start with a lowercase word: %s\n' "$label" "$subject" ;;
  esac

  if [[ $subject == *": "* ]]; then
    action=${subject#*": "}
    case $action in
    [!a-z]*) printf '%s: summary text after an area prefix must start lowercase: %s\n' "$label" "$subject" ;;
    esac
  fi

  if [[ $subject =~ $conventional_re ]]; then
    printf '%s: summary uses a conventional-commit prefix: %s\n' "$label" "$subject"
  fi
  case $subject in
  *.) printf '%s: summary ends with a period: %s\n' "$label" "$subject" ;;
  esac
}

commit_body_report() {
  local label=$1 body=$2 first
  [ -n "$body" ] || return 0

  first=$(printf '%s\n' "$body" | sed -n '1p')
  case $first in
  Why:\ [![:space:]]*) ;;
  *) printf '%s: description must begin with Why: and explain the reason for the change\n' "$label" ;;
  esac
}

# Every commit message rule that cap-commit can check before it returns. Keep
# this beside the landing check so a branch cannot pass one command and fail
# the other for the same message.
commit_rule_report() {
  local tree=$1 base=$2 hashes c short subject message second body ai
  hashes=$(git -C "$tree" log --format=%H "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check commit messages"

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    short=$(git -C "$tree" log -1 --format=%h "$c")
    subject=$(git -C "$tree" log -1 --format=%s "$c")
    message=$(git -C "$tree" log -1 --format=%B "$c")
    second=$(printf '%s\n' "$message" | sed -n '2p')
    body=$(printf '%s\n' "$message" | sed '1,2d')

    commit_subject_report "$short" "$subject"
    [ -z "$second" ] ||
      printf '%s: the second line must be blank\n' "$short"

    if [ -n "$body" ]; then
      commit_body_report "$short" "$body"
    fi
  done <<<"$hashes"

  ai=$(ai_trailer_report "$tree" "$base")
  [ -z "$ai" ] || printf '%s\n' "$ai"
}

commit_plan_shape_report() {
  local plan=$1 duplicates summary body count i
  [ -s "$plan" ] || {
    printf 'commit plan is missing: %s\n' "$plan"
    return 0
  }
  jq -e '
    (.commits | type == "array") and (.commits | length > 0) and
    all(.commits[];
      ((.summary | type) == "string" and (.summary | length) > 0) and
      ((.body == null) or
        ((.body | type) == "string" and (.body | length) > 0)) and
      ((.paths | type) == "array" and (.paths | length) > 0) and
      all(.paths[];
        (type == "string" and length > 0 and (startswith("/") | not) and ((split("/")[0]) != ".."))
      )
    )
  ' "$plan" >/dev/null 2>&1 || {
    printf 'commit plan must contain commits with summary, body, and relative paths: %s\n' "$plan"
    return 0
  }

  count=$(jq '.commits | length' "$plan")
  i=0
  while [ "$i" -lt "$count" ]; do
    summary=$(jq -r ".commits[$i].summary" "$plan")
    commit_subject_report "commit plan[$i]" "$summary"
    body=$(jq -r ".commits[$i].body // empty" "$plan")
    commit_body_report "commit plan[$i]" "$body"
    i=$((i + 1))
  done

  duplicates=$(jq -r '.commits[].paths[]' "$plan" | sort | uniq -d)
  [ -z "$duplicates" ] || {
    printf 'commit plan assigns a path to more than one commit: %s\n' "$(tr '\n' ' ' <<<"$duplicates")"
  }
}

commit_plan_message() {
  local plan=$1 index=$2 summary body message
  summary=$(jq -r ".commits[$index].summary" "$plan")
  body=$(jq -r ".commits[$index].body // empty" "$plan")
  message=$summary
  [ -z "$body" ] || message="$summary

$body"

  printf '%s\n' "$message" | grep -viE "$AI_TRAILER_RE" || true
}

commit_plan_write() {
  local tree=$1 plan=$2 count i planned_paths actual_paths message problems
  local -a paths

  problems=$(commit_plan_shape_report "$plan")
  [ -z "$problems" ] || die "cannot write commit plan:\n$problems"

  git -C "$tree" reset --quiet
  count=$(jq '.commits | length' "$plan")
  i=0
  while [ "$i" -lt "$count" ]; do
    mapfile -t paths < <(jq -r ".commits[$i].paths[]" "$plan")
    planned_paths=$(printf '%s\n' "${paths[@]}" | sort -u)

    git -C "$tree" add -A -- "${paths[@]}"
    actual_paths=$(git -C "$tree" diff --cached --no-renames --name-only | sort -u)
    [ "$actual_paths" = "$planned_paths" ] ||
      die "commit plan group $((i + 1)) staged paths do not match the plan"

    message=$(commit_plan_message "$plan" "$i")
    [ -n "$(printf '%s' "$message" | tr -d '[:space:]')" ] ||
      die "commit plan group $((i + 1)) has no message after cleanup"
    git -C "$tree" commit -q -F - <<<"$message"
    i=$((i + 1))
  done
}

commit_plan_paths_report() {
  local plan=$1 actual_paths=$2 planned_paths problems
  problems=$(commit_plan_shape_report "$plan")
  [ -z "$problems" ] || {
    printf '%s' "$problems"
    return 0
  }
  planned_paths=$(jq -r '.commits[].paths[]' "$plan" | sort -u)
  [ "$planned_paths" = "$actual_paths" ] || {
    printf 'commit plan paths do not cover exactly the changed files\n'
    printf '  planned: %s\n' "$(tr '\n' ' ' <<<"$planned_paths")"
    printf '  actual: %s\n' "$(tr '\n' ' ' <<<"$actual_paths")"
  }
}

commit_plan_report() {
  local tree=$1 base=$2 plan=$3 hashes c short expected_summary actual_summary expected_message actual_message
  local actual_paths planned_commit_paths actual_commit_paths count planned_count i problems
  problems=$(commit_plan_shape_report "$plan")
  [ -z "$problems" ] || {
    printf '%s' "$problems"
    return 0
  }

  hashes=$(git -C "$tree" log --reverse --format=%H "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check the commit plan"
  actual_paths=$(while IFS= read -r c; do
    [ -n "$c" ] || continue
    git -C "$tree" diff-tree --no-commit-id --name-only -r "$c"
  done <<<"$hashes" | sort -u)
  problems=$(commit_plan_paths_report "$plan" "$actual_paths")
  [ -z "$problems" ] || {
    printf '%s' "$problems"
    return 0
  }

  count=$(printf '%s\n' "$hashes" | sed '/^$/d' | wc -l | tr -d ' ')
  planned_count=$(jq '.commits | length' "$plan")
  [ "$count" = "$planned_count" ] || {
    printf 'commit plan has %s group(s), but the branch has %s commit(s)\n' "$planned_count" "$count"
    return 0
  }

  i=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    short=$(git -C "$tree" log -1 --format=%h "$c")
    expected_summary=$(jq -r ".commits[$i].summary" "$plan")
    actual_summary=$(git -C "$tree" log -1 --format=%s "$c")
    [ "$expected_summary" = "$actual_summary" ] ||
      printf '%s: plan summary is %s, commit summary is %s\n' "$short" "$expected_summary" "$actual_summary"

    planned_commit_paths=$(jq -r ".commits[$i].paths[]" "$plan" | sort -u)
    actual_commit_paths=$(git -C "$tree" diff-tree --no-commit-id --name-only -r "$c" | sort -u)
    [ "$planned_commit_paths" = "$actual_commit_paths" ] || {
      printf '%s: planned paths do not match the commit paths\n' "$short"
      printf '  planned: %s\n' "$(tr '\n' ' ' <<<"$planned_commit_paths")"
      printf '  actual: %s\n' "$(tr '\n' ' ' <<<"$actual_commit_paths")"
    }

    expected_message=$(commit_plan_message "$plan" "$i")
    actual_message=$(git -C "$tree" log -1 --format=%B "$c")
    [ "$actual_message" = "$expected_message" ] ||
      printf '%s: planned description does not match the commit body\n' "$short"
    i=$((i + 1))
  done <<<"$hashes"
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
