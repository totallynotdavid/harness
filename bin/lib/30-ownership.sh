# shellcheck shell=bash

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
      case $pa in "$pb"*)
        printf '%s overlaps %s\n' "${pa%/}" "${pb%/}"
        return 0
        ;;
      esac
      case $pb in "$pa"*)
        printf '%s overlaps %s\n' "${pa%/}" "${pb%/}"
        return 0
        ;;
      esac
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
  *)
    printf '^%s(/.*)?$' "$(printf '%s' "$1" | sed 's/[].^$+(){}|\[]/\\&/g')"
    return
    ;;
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
