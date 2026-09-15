# shellcheck shell=bash

queue_lock() {
  local slug=$1
  exec {QUEUE_FD}>>"$TASKS/$slug/.send-queue.lock"
  flock "$QUEUE_FD"
}

queue_unlock() {
  flock -u "$QUEUE_FD"
  exec {QUEUE_FD}>&-
}

# Base64 keeps each message on one line, so tabs and newlines in the text
# cannot be mistaken for queue separators.
queue_append() {
  local slug=$1 pid=$2 text=$3

  queue_lock "$slug"
  printf '%s\t%s\n' "$pid" "$(printf '%s' "$text" | base64 -w0)" \
    >>"$TASKS/$slug/send-queue"
  queue_unlock
}

# The queue has its own lock because this runs when the task lock is busy.
queue_send() {
  local slug=$1 text=$2 id
  id=$(session_identity)
  queue_append "$slug" "${id%@*}" "$text"
}

queue_pending() {
  [ -s "$TASKS/$1/send-queue" ] ||
    [ -s "$TASKS/$1/send-queue.flushing" ]
}

# Existing queued messages stay ahead of messages appended during recovery.
queue_prepend() {
  local slug=$1 file=$2
  local spool=$TASKS/$1/send-queue

  queue_lock "$slug"

  { cat "$file" "$spool" 2>/dev/null || true; } >"$spool.recovering"

  if mv "$spool.recovering" "$spool" 2>/dev/null; then
    queue_unlock
    return 0
  fi

  rm -f "$spool.recovering"
  queue_unlock
  return 1
}

# An unconfirmed submit may have left text in the input box. Do not type
# into that pane again until it has been replaced with a fresh input box.
queue_mark_untrusted() {
  : >"$TASKS/$1/.queue-untrusted"
}

queue_untrusted() {
  [ -f "$TASKS/$1/.queue-untrusted" ]
}

queue_clear_untrusted() {
  rm -f "$TASKS/$1/.queue-untrusted"
}

# A process killed during a flush may leave its claimed batch behind.
# Recover it before claiming another batch.
queue_recover_stranded() {
  local slug=$1
  local claimed=$TASKS/$1/send-queue.flushing

  [ -f "$claimed" ] || return 0

  if queue_prepend "$slug" "$claimed"; then
    rm -f "$claimed"
    return 0
  fi

  warn "$slug: could not recover queued messages in $claimed; left in place, will retry on the next flush"
  return 1
}

# Typing into a blocked prompt could select or approve an option.
pane_usable() {
  agent_live "$1" || return 1
  [ "$(pane_agent_status "$1")" != blocked ]
}

# Rename the spool before reading it so new messages go to a fresh spool.
queue_claim() {
  local slug=$1
  local dir=$TASKS/$1
  local rc

  queue_lock "$slug"
  mv "$dir/send-queue" "$dir/send-queue.flushing" 2>/dev/null
  rc=$?
  queue_unlock

  return "$rc"
}

# Remove the message before submitting it. If the process dies during
# submission, retrying could send the same message twice.
queue_drop_claimed_line() {
  local claimed=$1
  local tmp=$1.tail

  tail -n +2 "$claimed" >"$tmp" 2>/dev/null || : >"$tmp"
  mv "$tmp" "$claimed"
}

queue_deliver_claimed() {
  local slug=$1
  local dir=$TASKS/$1
  local claimed=$TASKS/$1/send-queue.flushing
  local pid b64 text line

  while [ -s "$claimed" ]; do
    line=$(head -n1 "$claimed")
    queue_drop_claimed_line "$claimed"

    [ -n "$line" ] || continue

    pid=${line%%$'\t'*}
    b64=${line#*$'\t'}
    text=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)

    if pane_submit "$slug" "$text"; then
      printf 'working: sent by %s: %s\n' \
        "$(session_label "$pid")" \
        "$(printf '%s' "$text" | tr '\n' ' ')" \
        >>"$dir/status.log"
      continue
    fi

    warn "$slug: a queued message from $(session_label "$pid") was typed but never confirmed; will not be retried - check by hand: cap peek $slug"
    printf 'unconfirmed: sent by %s: %s\n' \
      "$(session_label "$pid")" \
      "$(printf '%s' "$text" | tr '\n' ' ')" \
      >>"$dir/status.log"

    queue_mark_untrusted "$slug"
    return 1
  done

  rm -f "$claimed"
}

queue_flush() {
  local slug=$1

  queue_untrusted "$slug" && return 1
  queue_recover_stranded "$slug" || return 1

  [ -s "$TASKS/$slug/send-queue" ] || return 0
  pane_usable "$slug" || return 1

  queue_claim "$slug" || return 0
  queue_deliver_claimed "$slug"
}
