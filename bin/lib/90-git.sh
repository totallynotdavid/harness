# shellcheck shell=bash

git_dirty() {
  git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '
}

git_dirty_tracked() {
  git -C "$1" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' '
}

sync_base() {
  local tree=$1 base=$2 base_tip merge_base dirty stashed=0

  base_tip=$(git -C "$tree" rev-parse "$base" 2>/dev/null) || return 0
  merge_base=$(git -C "$tree" merge-base HEAD "$base" 2>/dev/null) || return 0
  [ "$base_tip" = "$merge_base" ] && return 0

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

diff_base() {
  local tree=$1 base=$2 merge_base

  merge_base=$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null) || true
  printf '%s' "${merge_base:-$base}"
}

gate_fingerprint_from() {
  local tree=$1 from=$2 file pid rc

  # Failures inside process substitution do not reach the while loop.
  # Disable errexit here so we can check ls-files ourselves.
  set +e
  {
    git -C "$tree" diff "$from" 2>/dev/null || true

    while IFS= read -r -d '' file; do
      # Include the path so renames change the fingerprint.
      printf '=== %s\n' "$file"
      cat -- "$tree/$file" 2>/dev/null || true
    done < <(git -C "$tree" ls-files --others --exclude-standard -z 2>/dev/null | sort -z)

    pid=$!
    wait "$pid" || exit 1
  } | sha256sum | cut -d' ' -f1
  rc=$?
  set -e

  [ "$rc" = 0 ] ||
    die "gate_fingerprint_from: could not list untracked files in $tree"
}

gate_fingerprint() {
  local tree=$1 base=$2

  base=$(diff_base "$tree" "$base")
  gate_fingerprint_from "$tree" "$base"
}

reviewable_files() {
  local tree=$1 from=$2 tracked untracked

  tracked=$(git -C "$tree" diff --name-only "$from") || return 1
  untracked=$(git -C "$tree" ls-files --others --exclude-standard) || return 1

  printf '%s\n%s\n' "$tracked" "$untracked" | sed '/^$/d' | sort -u
}

task_round() {
  local count

  count=$(grep -c '^done:' "$TASKS/$1/status.log" 2>/dev/null) || true
  printf '%s' "${count:-0}"
}

step_record() {
  local slug=$1 step=$2 result=$3
  local file=$TASKS/$slug/steps.json tmp previous

  previous=$([ -f "$file" ] && cat "$file" || echo '{}')
  tmp=$(mktemp)

  if jq -n \
    --argjson prev "$previous" \
    --arg step "$step" \
    --arg result "$result" \
    --argjson round "$(task_round "$slug")" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$prev + {($step): {round: $round, result: $result, at: $at}}' \
    >"$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    warn "could not record step $step for $slug"
  fi
}

step_ran() {
  local slug=$1 step=$2
  local file=$TASKS/$slug/steps.json

  [ -f "$file" ] || return 1

  [ "$(jq -r --arg s "$step" '.[$s].round // -1' "$file" 2>/dev/null)" = \
    "$(task_round "$slug")" ]
}

gate_record() {
  local slug=$1 label=$2 verdict=$3 fingerprint=$4 commit=$5 since=$6
  local file=$TASKS/$slug/gate.json tmp previous

  previous=$([ -f "$file" ] && cat "$file" || echo '{}')
  tmp=$(mktemp)

  if jq -n \
    --argjson prev "$previous" \
    --arg label "$label" \
    --arg verdict "$verdict" \
    --arg fp "$fingerprint" \
    --arg commit "$commit" \
    --arg since "$since" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$prev + {($label): {verdict: $verdict, fingerprint: $fp, commit: $commit, since: $since, at: $at}}' \
    >"$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    warn "could not record gate verdict for $slug/$label"
  fi
}

gate_passes_fingerprint() {
  local slug=$1 label=$2 fingerprint=$3
  local file=$TASKS/$slug/gate.json

  [ -f "$file" ] || return 1

  jq -e \
    --arg label "$label" \
    --arg fp "$fingerprint" \
    '.[$label].verdict == "PASS" and .[$label].fingerprint == $fp' \
    "$file" >/dev/null 2>&1
}

gate_last_commit() {
  local slug=$1 label=$2
  local file=$TASKS/$slug/gate.json

  [ -f "$file" ] || return 0
  jq -r --arg label "$label" '.[$label].commit // empty' "$file" 2>/dev/null || true
}

gate_review_since() {
  local slug=$1 label=$2 tree=$3 base=$4
  local full since verdict head
  local current_merge_base previous_merge_base
  local reviewed_since reviewed_fingerprint

  full=$(diff_base "$tree" "$base")
  since=$(gate_last_commit "$slug" "$label")

  if [ -z "$since" ]; then
    printf '%s' "$full"
    return
  fi

  if ! git -C "$tree" cat-file -e "$since" 2>/dev/null; then
    printf '%s' "$full"
    return
  fi

  if ! git -C "$tree" merge-base --is-ancestor "$since" HEAD 2>/dev/null; then
    printf '%s' "$full"
    return
  fi

  # Only a PASS can be used as the start of an incremental review.
  verdict=$(jq -r \
    --arg label "$label" \
    '.[$label].verdict // empty' \
    "$TASKS/$slug/gate.json" 2>/dev/null || true)

  if [ "$verdict" != PASS ]; then
    printf '%s' "$full"
    return
  fi

  # Syncing base can move the fork point. In that case the old commit no
  # longer describes the same review range.
  current_merge_base=$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null || true)
  previous_merge_base=$(git -C "$tree" merge-base "$base" "$since" 2>/dev/null || true)

  if [ "$current_merge_base" != "$previous_merge_base" ]; then
    printf '%s' "$full"
    return
  fi

  head=$(git -C "$tree" rev-parse HEAD)

  if [ "$since" != "$head" ]; then
    printf '%s' "$since"
    return
  fi

  reviewed_since=$(jq -r \
    --arg label "$label" \
    '.[$label].since // empty' \
    "$TASKS/$slug/gate.json" 2>/dev/null || true)

  reviewed_fingerprint=$(jq -r \
    --arg label "$label" \
    '.[$label].fingerprint // empty' \
    "$TASKS/$slug/gate.json" 2>/dev/null || true)

  # The previous PASS still covers this exact tree.
  if [ -n "$reviewed_since" ] &&
    git -C "$tree" cat-file -e "$reviewed_since" 2>/dev/null &&
    [ "$reviewed_fingerprint" = "$(gate_fingerprint_from "$tree" "$reviewed_since")" ]; then
    return
  fi

  if [ "$(git_dirty "$tree")" != 0 ]; then
    printf '%s' "$since"
  else
    printf '%s' "$full"
  fi
}

gate_ready() {
  local slug=$1 tree=$2 base=$3
  local file=$TASKS/$slug/gate.json
  local current a_verdict a_fingerprint b_verdict b_fingerprint

  [ -f "$file" ] || return 1

  a_verdict=$(jq -r '.A.verdict // empty' "$file" 2>/dev/null || true)
  b_verdict=$(jq -r '.B.verdict // empty' "$file" 2>/dev/null || true)

  # Avoid hashing the tree until both gates have passed.
  [ "$a_verdict" = PASS ] && [ "$b_verdict" = PASS ] || return 1

  [ -n "$(reviewable_files "$tree" "$(diff_base "$tree" "$base")")" ] || return 1

  a_fingerprint=$(jq -r '.A.fingerprint // empty' "$file" 2>/dev/null || true)
  b_fingerprint=$(jq -r '.B.fingerprint // empty' "$file" 2>/dev/null || true)
  current=$(gate_fingerprint "$tree" "$base")

  [ "$a_fingerprint" = "$current" ] && [ "$b_fingerprint" = "$current" ]
}

gate_failed_here() {
  local slug=$1 tree=$2 base=$3
  local file=$TASKS/$slug/gate.json current

  [ -f "$file" ] || return 1

  jq -e \
    '[.A, .B] | any(. != null and .verdict == "FAIL")' \
    "$file" >/dev/null 2>&1 || return 1

  current=$(gate_fingerprint "$tree" "$base")

  jq -e \
    --arg fp "$current" \
    '[.A, .B] | any(. != null and .verdict == "FAIL" and .fingerprint == $fp)' \
    "$file" >/dev/null 2>&1
}

AI_TRAILER_RE='^(claude|codex)-session:|generated with \[(claude code|codex)\]|^co-authored-by:[[:space:]]*(claude|codex|chatgpt|gpt)\b|^co-authored-by:.*<noreply@(anthropic|openai)\.com>'

git_ensure_attribution_hook() {
  local tree=$1 gitdir hook

  gitdir=$(git -C "$tree" rev-parse --git-common-dir 2>/dev/null) || return 0

  case $gitdir in
  /*) ;;
  *) gitdir=$tree/$gitdir ;;
  esac

  hook=$gitdir/hooks/commit-msg

  [ -f "$hook" ] &&
    grep -qF "$AI_TRAILER_RE" "$hook" 2>/dev/null &&
    return 0

  mkdir -p "$gitdir/hooks" || return 0

  cat >"$hook" <<HOOK || return 0
#!/usr/bin/env bash
# Strip generated AI attribution before the commit reaches history.
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

git_ensure_push_hook() {
  local tree=$1 gitdir hook

  gitdir=$(git -C "$tree" rev-parse --git-common-dir 2>/dev/null) || return 0

  case $gitdir in
  /*) ;;
  *) gitdir=$tree/$gitdir ;;
  esac

  hook=$gitdir/hooks/post-commit

  [ -f "$hook" ] &&
    grep -qF 'Captain: push after every commit' "$hook" 2>/dev/null &&
    return 0

  mkdir -p "$gitdir/hooks" || return 0

  cat >"$hook" <<'HOOK' || return 0
#!/usr/bin/env bash
# Captain: push after every commit in this checkout. Every host runs an
# independent clone with no other sync, so an unpushed fix here is a bug
# another host will hit again. A post-commit hook cannot block the commit
# it fires after, and this never forces: a rejected push leaves the local
# commit for task-status.sh's ahead-count line to surface.
branch=$(git symbolic-ref --short -q HEAD) || exit 0
git push -q origin "HEAD:$branch" 2>/dev/null &&
  printf 'captain: pushed to origin/%s\n' "$branch"
exit 0
HOOK

  chmod +x "$hook" 2>/dev/null || true
}

ai_trailer_report() {
  local tree=$1 base=$2 commit hashes

  # Capture git log first so an invalid range cannot look like an empty range.
  hashes=$(git -C "$tree" log --format=%h "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check attribution"

  [ -z "$hashes" ] && return 0

  while IFS= read -r commit; do
    # grep returns 1 when a commit has no matching attribution.
    git -C "$tree" log -1 --format='%B' "$commit" |
      { grep -inE "$AI_TRAILER_RE" || true; } |
      sed "s/^/$commit: /"
  done <<<"$hashes"
}

commit_subject_report() {
  local label=$1 subject=$2 action
  local conventional_re='^(revert:[[:space:]])?(feat|fix|docs|style|refactor|perf|test|build|ci|chore)(\([^)]*\))?!?:[[:space:]]'

  [ -n "$subject" ] ||
    printf '%s: summary is empty\n' "$label"

  case $subject in
  *$'\n'*)
    printf '%s: summary must be one line\n' "$label"
    ;;
  [!a-z]*)
    printf '%s: summary must start with a lowercase word: %s\n' "$label" "$subject"
    ;;
  esac

  if [[ $subject == *": "* ]]; then
    action=${subject#*": "}

    case $action in
    [!a-z]*)
      printf '%s: summary text after an area prefix must start lowercase: %s\n' \
        "$label" "$subject"
      ;;
    esac
  fi

  if [[ $subject =~ $conventional_re ]]; then
    printf '%s: summary uses a conventional-commit prefix: %s\n' "$label" "$subject"
  fi

  case $subject in
  *.)
    printf '%s: summary ends with a period: %s\n' "$label" "$subject"
    ;;
  esac
}

commit_body_report() {
  local label=$1 body=$2 first

  [ -n "$body" ] || return 0

  first=$(printf '%s\n' "$body" | sed -n '1p')

  case $first in
  Why:\ [![:space:]]*) ;;
  *)
    printf '%s: description must begin with Why: and explain the reason for the change\n' \
      "$label"
    ;;
  esac
}

commit_rule_report() {
  local tree=$1 base=$2 hashes commit short subject message second body ai

  hashes=$(git -C "$tree" log --format=%H "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check commit messages"

  while IFS= read -r commit; do
    [ -n "$commit" ] || continue

    short=$(git -C "$tree" log -1 --format=%h "$commit")
    subject=$(git -C "$tree" log -1 --format=%s "$commit")
    message=$(git -C "$tree" log -1 --format=%B "$commit")
    second=$(printf '%s\n' "$message" | sed -n '2p')
    body=$(printf '%s\n' "$message" | sed '1,2d')

    commit_subject_report "$short" "$subject"

    [ -z "$second" ] ||
      printf '%s: the second line must be blank\n' "$short"

    commit_body_report "$short" "$body"
  done <<<"$hashes"

  ai=$(ai_trailer_report "$tree" "$base")
  [ -z "$ai" ] || printf '%s\n' "$ai"
}

commit_plan_shape_report() {
  local plan=$1 duplicates summary body count i

  if [ ! -s "$plan" ]; then
    printf 'commit plan is missing: %s\n' "$plan"
    return 0
  fi

  jq -e '
    (.commits | type == "array") and
    (.commits | length > 0) and
    all(.commits[];
      ((.summary | type) == "string" and (.summary | length) > 0) and
      ((.body == null) or
        ((.body | type) == "string" and (.body | length) > 0)) and
      ((.paths | type) == "array" and (.paths | length) > 0) and
      all(.paths[];
        (
          type == "string" and
          length > 0 and
          (startswith("/") | not) and
          ((split("/")[0]) != "..")
        )
      )
    )
  ' "$plan" >/dev/null 2>&1 || {
    printf 'commit plan must contain commits with summary, body, and relative paths: %s\n' \
      "$plan"
    return 0
  }

  count=$(jq '.commits | length' "$plan")

  i=0
  while [ "$i" -lt "$count" ]; do
    summary=$(jq -r ".commits[$i].summary" "$plan")
    body=$(jq -r ".commits[$i].body // empty" "$plan")

    commit_subject_report "commit plan[$i]" "$summary"
    commit_body_report "commit plan[$i]" "$body"

    i=$((i + 1))
  done

  duplicates=$(jq -r '.commits[].paths[]' "$plan" | sort | uniq -d)

  if [ -n "$duplicates" ]; then
    printf 'commit plan assigns a path to more than one commit: %s\n' \
      "$(tr '\n' ' ' <<<"$duplicates")"
  fi
}

commit_plan_message() {
  local plan=$1 index=$2 summary body

  summary=$(jq -r ".commits[$index].summary" "$plan")
  body=$(jq -r ".commits[$index].body // empty" "$plan")

  if [ -n "$body" ]; then
    printf '%s\n\n%s\n' "$summary" "$body"
  else
    printf '%s\n' "$summary"
  fi | grep -viE "$AI_TRAILER_RE" || true
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
  if [ -n "$problems" ]; then
    printf '%s' "$problems"
    return 0
  fi

  planned_paths=$(jq -r '.commits[].paths[]' "$plan" | sort -u)

  if [ "$planned_paths" != "$actual_paths" ]; then
    printf 'commit plan paths do not cover exactly the changed files\n'
    printf '  planned: %s\n' "$(tr '\n' ' ' <<<"$planned_paths")"
    printf '  actual: %s\n' "$(tr '\n' ' ' <<<"$actual_paths")"
  fi
}

commit_plan_report() {
  local tree=$1 base=$2 plan=$3
  local hashes commit short expected_summary actual_summary
  local expected_message actual_message actual_paths
  local planned_commit_paths actual_commit_paths
  local count planned_count i problems

  problems=$(commit_plan_shape_report "$plan")
  if [ -n "$problems" ]; then
    printf '%s' "$problems"
    return 0
  fi

  hashes=$(git -C "$tree" log --reverse --format=%H "$base..HEAD") ||
    die "could not list commits $base..HEAD in $tree; cannot check the commit plan"

  actual_paths=$(
    while IFS= read -r commit; do
      [ -n "$commit" ] || continue
      git -C "$tree" diff-tree --no-commit-id --name-only -r "$commit"
    done <<<"$hashes" | sort -u
  )

  problems=$(commit_plan_paths_report "$plan" "$actual_paths")
  if [ -n "$problems" ]; then
    printf '%s' "$problems"
    return 0
  fi

  count=$(printf '%s\n' "$hashes" | sed '/^$/d' | wc -l | tr -d ' ')
  planned_count=$(jq '.commits | length' "$plan")

  if [ "$count" != "$planned_count" ]; then
    printf 'commit plan has %s group(s), but the branch has %s commit(s)\n' \
      "$planned_count" "$count"
    return 0
  fi

  i=0
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue

    short=$(git -C "$tree" log -1 --format=%h "$commit")

    expected_summary=$(jq -r ".commits[$i].summary" "$plan")
    actual_summary=$(git -C "$tree" log -1 --format=%s "$commit")

    if [ "$expected_summary" != "$actual_summary" ]; then
      printf '%s: plan summary is %s, commit summary is %s\n' \
        "$short" "$expected_summary" "$actual_summary"
    fi

    planned_commit_paths=$(jq -r ".commits[$i].paths[]" "$plan" | sort -u)
    actual_commit_paths=$(
      git -C "$tree" diff-tree --no-commit-id --name-only -r "$commit" | sort -u
    )

    if [ "$planned_commit_paths" != "$actual_commit_paths" ]; then
      printf '%s: planned paths do not match the commit paths\n' "$short"
      printf '  planned: %s\n' "$(tr '\n' ' ' <<<"$planned_commit_paths")"
      printf '  actual: %s\n' "$(tr '\n' ' ' <<<"$actual_commit_paths")"
    fi

    expected_message=$(commit_plan_message "$plan" "$i")
    actual_message=$(git -C "$tree" log -1 --format=%B "$commit")

    [ "$actual_message" = "$expected_message" ] ||
      printf '%s: planned description does not match the commit body\n' "$short"

    i=$((i + 1))
  done <<<"$hashes"
}

git_branch() {
  git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null ||
    git -C "$1" rev-parse --short HEAD 2>/dev/null ||
    echo '-'
}

git_base() {
  local base

  base=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null |
    sed 's|^origin/||')

  [ -n "$base" ] || base=$(git_branch "$1")
  [ -n "$base" ] && [ "$base" != '-' ] || base=main

  printf '%s' "$base"
}

harness_trust() {
  local harness=$1 dir=$2 root config tmp

  case $harness in
  claude)
    [ -f "$HOME/.claude.json" ] || return 0

    # Parallel launches should not rewrite the shared file when already trusted.
    jq -e \
      --arg dir "$dir" \
      '.projects[$dir].hasTrustDialogAccepted == true' \
      "$HOME/.claude.json" >/dev/null 2>&1 &&
      return 0

    tmp=$(mktemp)

    if jq \
      --arg dir "$dir" \
      '.projects[$dir] = ((.projects[$dir] // {}) + {hasTrustDialogAccepted: true})' \
      "$HOME/.claude.json" >"$tmp" 2>/dev/null &&
      [ -s "$tmp" ]; then
      if ! cp "$HOME/.claude.json" "$HOME/.claude.json.cap-bak" ||
        ! mv "$tmp" "$HOME/.claude.json"; then
        rm -f "$tmp"
        warn "could not trust $dir; the agent may stop on the trust dialog"
      fi
    else
      rm -f "$tmp"
      warn "could not trust $dir; the agent may stop on the trust dialog"
    fi
    ;;

  codex)
    # Codex stores trust at the shared repo root, not per worktree.
    root=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
      root=$(dirname "$root") ||
      root=$dir

    config=$HOME/.codex/config.toml

    if [ -f "$config" ] && ! grep -qF "[projects.\"$root\"]" "$config"; then
      cp "$config" "$config.cap-bak"
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$root" >>"$config"
    fi
    ;;
  esac
}
