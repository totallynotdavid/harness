# shellcheck shell=bash

ask_profile() {
  printf '%s\n' "$CAP_ASK_PROFILES" |
    awk -v p="$1" '$1==p {print $2, $3, ($4 == "" ? "-" : $4); found=1} END{exit !found}' ||
    die "unknown ask profile '$1' (see config/captain.conf)"
}

CAP_USAGE_DIR=$CAP_HOME/state/usage
CAP_BLOCK_DIR=$CAP_USAGE_DIR/blocked
CAP_DISPATCH_LOG=$CAP_USAGE_DIR/dispatch.jsonl

usage_files() {
  compgen -G "$CAP_USAGE_DIR/*.json" >/dev/null 2>&1
}

codex_rpc() {
  local method=$1
  local params=${2:-'{}'}
  local dir writer server
  local rc=1
  local i

  command -v codex >/dev/null 2>&1 || return 1

  dir=$(mktemp -d) || return 1
  if ! mkfifo "$dir/in" 2>/dev/null; then
    rm -rf "$dir"
    return 1
  fi

  {
    printf '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"captain","version":"1"}}}\n'
    printf '{"id":2,"method":"%s","params":%s}\n' "$method" "$params"

    # Keep stdin open until the async reply arrives. EOF makes the app-server
    # exit before it can answer.
    exec sleep 30
  } >"$dir/in" 2>/dev/null &
  writer=$!

  timeout 30 codex app-server <"$dir/in" >"$dir/out" 2>/dev/null &
  server=$!

  for ((i = 0; i < 100; i++)); do
    if grep -q '"id":2' "$dir/out" 2>/dev/null; then
      rc=0
      break
    fi

    if ! kill -0 "$server" 2>/dev/null; then
      break
    fi

    sleep 0.05
  done

  kill "$writer" "$server" 2>/dev/null || true
  wait "$writer" "$server" 2>/dev/null || true

  if [ "$rc" = 0 ]; then
    grep -h '"id":2' "$dir/out" | tail -1
  fi

  rm -rf "$dir"
  return "$rc"
}

codex_cached() {
  local name=$1
  local ttl=$2
  local method=$3
  local params=${4:-'{}'}
  local file age out

  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 1
  file=$CAP_USAGE_DIR/$name

  if [ -f "$file" ]; then
    age=$(($(now) - $(stat -c %Y "$file" 2>/dev/null || echo 0)))

    if [ "$age" -lt "$ttl" ]; then
      [ -s "$file" ] || return 1
      cat "$file"
      return 0
    fi
  fi

  out=$(codex_rpc "$method" "$params" 2>/dev/null |
    jq -c '.result // empty' 2>/dev/null) || out=""

  if [ -z "$out" ] && [ -s "$file" ]; then
    # Keep stale data when refresh fails. Retrying every dispatch would only
    # repeat the same timeout.
    touch "$file"
    cat "$file"
    return 0
  fi

  printf '%s' "$out" >"$file"

  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

codex_catalog() {
  codex_cached codex-models.json 86400 model/list '{"includeHidden":false}'
}

profile_check() {
  local profile=$1
  local harness model effort catalog problem

  read -r harness model effort <<<"$(ask_profile "$profile")"

  # A role can override the profile's configured effort for this session.
  [ -z "${2:-}" ] || effort=$2

  [ "$harness" = codex ] || return 0
  [ "$model" != '-' ] || return 0

  # Failure to read the catalog does not mean the profile is invalid.
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

codex_rollout() {
  find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -mmin -1440 \
    -printf '%T@ %p\n' 2>/dev/null |
    sort -rn |
    head -1 |
    cut -d' ' -f2-
}

codex_limit_reached() {
  codex_rate_limits |
    jq -r '.rate_limit_reached_type // empty' 2>/dev/null ||
    true
}

codex_rollout_limits() {
  local file

  file=$(codex_rollout)
  [ -n "$file" ] || return 1

  grep -h '"rate_limits"' "$file" 2>/dev/null |
    tail -1 |
    jq -e '.payload.rate_limits // empty' 2>/dev/null
}

codex_rate_limits() {
  local live

  if live=$(codex_cached codex-limits.json "${CAP_USAGE_TTL:-900}" account/rateLimits/read); then
    # Normalize the app-server fields to the rollout shape so callers can use
    # either source without branching.
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

  codex_rollout_limits |
    jq -e '. + {source: "rollout"}' 2>/dev/null
}

usage_read() {
  local harness=${1:-claude}
  local cutoff out

  cutoff=$(($(now) - ${CAP_USAGE_TTL:-900}))

  if usage_files; then
    # Headless records omit spend_limit, so use its newest fresh observation
    # instead of assuming the newest record cleared it.
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
    # Rollout data can outlive its window, so expired windows count as empty.
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

  # Claude refreshes ~/.claude.json less often, so it gets a longer fallback TTL.
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

usage_detail() {
  local harness=$1
  local source=$2

  case $harness:$source in
  claude:cache)
    printf 'from the harness cache in ~/.claude.json'
    ;;

  claude:*)
    usage_files || return 0

    jq -rs --arg h "$harness" '
      map(select((.harness // "claude") == $h))
      | if length == 0 then "" else
          (max_by(.at)
           | "5h \(.five_hour.pct // 0 | floor)%, 7d \(.seven_day.pct // 0 | floor)%, read \(now - .at | floor)s ago")
        end
    ' "$CAP_USAGE_DIR"/*.json 2>/dev/null || true
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

profile_block() {
  local profile=$1
  local until=${2:-0}

  [ "$until" -gt "$(now)" ] 2>/dev/null ||
    until=$(($(now) + ${CAP_BLOCK_SECS:-3600}))

  mkdir -p "$CAP_BLOCK_DIR"
  printf '%s\n' "$until" >"$CAP_BLOCK_DIR/$profile"
}

profile_block_until() {
  cat "$CAP_BLOCK_DIR/$1" 2>/dev/null || printf '0'
}

profile_blocked() {
  local until

  until=$(profile_block_until "$1")

  if [ "$until" -gt "$(now)" ] 2>/dev/null; then
    return 0
  fi

  rm -f "$CAP_BLOCK_DIR/$1"
  return 1
}

dispatch_log() {
  local entry

  entry=$(jq -nc \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg caller "${0##*/}" \
    --arg role "$1" \
    --arg profile "$2" \
    --arg harness "$3" \
    --arg pct "$4" \
    '{at: $at, caller: $caller, kind: "size", role: $role, profile: $profile, harness: $harness, pct: $pct}')

  dispatch_log_json "$entry"
}

dispatch_log_json() {
  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$CAP_DISPATCH_LOG" 2>/dev/null || return 0

  if [ "$(stat -c %s "$CAP_DISPATCH_LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 400 "$CAP_DISPATCH_LOG" >"$CAP_DISPATCH_LOG.tmp" 2>/dev/null &&
      mv "$CAP_DISPATCH_LOG.tmp" "$CAP_DISPATCH_LOG"
  fi
}

role_tier() {
  local var

  var=CAP_ROLE_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-}"
}

role_effort() {
  local var

  var=CAP_EFFORT_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
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

tier_profile() {
  local tier=$1
  local role=$2
  local avoid=${3:-}
  local peers profile admit pct pair harness

  peers=$(tier_peers "$tier")
  [ -n "$peers" ] ||
    die "tier '$tier' lists no profiles (see config/captain.conf)"

  admit=$(tier_admit "$tier")

  for profile in $peers; do
    if [ "$profile" = "$avoid" ]; then
      continue
    fi

    if profile_blocked "$profile"; then
      continue
    fi

    # Unknown peers are config errors. Do not treat them as profiles with
    # unknown usage.
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
  local role=$1
  local tier

  tier=$(role_tier "$role")
  [ -n "$tier" ] ||
    die "unknown dispatch role '$role' (see config/captain.conf)"

  tier_profile "$tier" "$role" "${2:-}"
}

role_profile_or_die() {
  local role=$1
  local tier=${2:-}
  local profile pair harness pct resets source until
  local selected
  local soonest=0
  local detail=""
  local message

  [ -n "$tier" ] || tier=$(role_tier "$role")
  [ -n "$tier" ] ||
    die "unknown dispatch role '$role' (see config/captain.conf)"

  if selected=$(tier_profile "$tier" "$role"); then
    printf '%s' "$selected"
    return 0
  fi

  for profile in $(tier_peers "$tier"); do
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
    read -r pct resets source <<<"$(usage_read "$harness")"

    detail="$detail $profile($harness at $pct%, source $source)"

    if [ "$resets" -gt "$(now)" ] 2>/dev/null; then
      if [ "$soonest" = 0 ] || [ "$resets" -lt "$soonest" ]; then
        soonest=$resets
      fi
    fi
  done

  # Do not fall back to a lower tier. The role's tier is a capability
  # requirement, not a preference.
  message="no $tier profile can take role '$role' right now:$detail"

  if [ "$soonest" -gt "$(now)" ] 2>/dev/null; then
    message="$message. Earliest capacity at $(date -d "@$soonest" '+%H:%M')"
  fi

  die "$message. run: cap budget"
}
