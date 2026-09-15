# shellcheck shell=bash

owns_read() {
  local file=$TASKS/$1/owns

  [ -f "$file" ] || return 0

  tr '\n' ' ' <"$file" | sed 's/  */ /g; s/^ //; s/ $//'
}

owns_write() {
  local slug=$1
  shift

  mkdir -p "$TASKS/$slug"
  printf '%s\n' "$@" >"$TASKS/$slug/owns"
}

owns_prefix() {
  local glob=${1%%[*?[]*}

  printf '%s' "${glob%/}"
}

owns_files() {
  local tree=$1
  local glob
  shift

  for glob in "$@"; do
    git -C "$tree" ls-files -co --exclude-standard -- ":(glob)$glob" 2>/dev/null || true
  done | sort -u
}

owns_overlap() {
  local tree=$1
  local shared
  local prefix_a
  local prefix_b
  local -a globs_a
  local -a globs_b

  read -r -a globs_a <<<"$2"
  read -r -a globs_b <<<"$3"

  [ "${#globs_a[@]}" -gt 0 ] || return 1
  [ "${#globs_b[@]}" -gt 0 ] || return 1

  shared=$(
    comm -12 \
      <(owns_files "$tree" "${globs_a[@]}") \
      <(owns_files "$tree" "${globs_b[@]}") 2>/dev/null || true
  )

  if [ -n "$shared" ]; then
    printf '%s\n' "$shared"
    return 0
  fi

  # Prefixes catch overlap before either task creates a matching file.
  for glob_a in "${globs_a[@]}"; do
    prefix_a=$(owns_prefix "$glob_a")/

    for glob_b in "${globs_b[@]}"; do
      prefix_b=$(owns_prefix "$glob_b")/

      if [[ $prefix_a == "$prefix_b"* || $prefix_b == "$prefix_a"* ]]; then
        printf '%s overlaps %s\n' "${prefix_a%/}" "${prefix_b%/}"
        return 0
      fi
    done
  done

  return 1
}

owns_regex() {
  case $1 in
  *[*?]*) ;;
  *)
    # A plain path claims the path and everything below it.
    printf '^%s(/.*)?$' "$(printf '%s' "$1" | sed 's/[].^$+(){}|\[]/\\&/g')"
    return
    ;;
  esac

  # ** crosses directories. * and ? stay within one directory.
  printf '%s' "$1" | awk '{
    out = ""
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "*") {
        if (substr($0, i + 1, 1) == "*") {
          out = out ".*"
          i++
        } else {
          out = out "[^/]*"
        }
      } else if (c == "?") {
        out = out "[^/]"
      } else if (index(".^$+(){}[]|\\", c) > 0) {
        out = out "\\" c
      } else {
        out = out c
      }
    }
    print "^" out "$"
  }'
}

owns_claims() {
  local path=$1
  local glob
  shift

  for glob in "$@"; do
    if printf '%s\n' "$path" | grep -qE "$(owns_regex "$glob")"; then
      return 0
    fi
  done

  return 1
}

owns_taken() {
  local project=$1
  local tree=$2
  local globs=$3
  local self=${4:-}
  local other
  local other_tree
  local overlap
  local found=1

  for other in $(task_slugs); do
    [ "$other" != "$self" ] || continue
    [ "$(task_field "$other" CAP_PROJECT 2>/dev/null || true)" = "$project" ] || continue

    other_tree=$(task_field "$other" CAP_TREE 2>/dev/null || true)
    [ -n "$other_tree" ] || continue
    [ -e "$other_tree/.git" ] || continue

    overlap=$(owns_overlap "$tree" "$globs" "$(owns_read "$other")") || continue

    printf '%s claims:\n' "$other"
    printf '%s\n' "$overlap" | sed 's/^/    /'
    found=0
  done

  return "$found"
}
