# shellcheck shell=bash

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
  # A role's effort, when the dispatcher passes one, is the effort the session runs.
  [ -z "${2:-}" ] || effort=$2
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
  find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' -mmin -1440 \
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
CAP_DISPATCH_LOG=$CAP_USAGE_DIR/dispatch.jsonl

# One JSON object per line. A sizing decision (kind "size") is written here
# when a role picks a profile; bin/caplib.py writes what the dispatch then
# cost (kind "cost") to the same log through dispatch_log_json.
dispatch_log() {
  dispatch_log_json "$(jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg caller "${0##*/}" \
    --arg role "$1" --arg profile "$2" --arg harness "$3" --arg pct "$4" \
    '{at: $at, caller: $caller, kind: "size", role: $role, profile: $profile, harness: $harness, pct: $pct}')"
}

dispatch_log_json() {
  mkdir -p "$CAP_USAGE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$CAP_DISPATCH_LOG" 2>/dev/null || return 0
  # Keep the tail, drop the history. Nobody audits a dispatch from last month.
  if [ "$(stat -c %s "$CAP_DISPATCH_LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 400 "$CAP_DISPATCH_LOG" >"$CAP_DISPATCH_LOG.tmp" 2>/dev/null &&
      mv "$CAP_DISPATCH_LOG.tmp" "$CAP_DISPATCH_LOG"
  fi
}

# What kind of thinking a role needs, and which profiles can supply it.
role_tier() {
  local var
  var=CAP_ROLE_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')
  printf '%s' "${!var:-}"
}

# The reasoning effort a role runs at, or empty for the harness default. A
# profile that names its own effort keeps it: terra at xhigh is what that
# profile means.
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
