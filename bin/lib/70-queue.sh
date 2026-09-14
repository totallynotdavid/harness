# shellcheck shell=bash

# One line per queued message: pid (possibly empty, see session_identity),
# a tab, then the text base64-encoded - not tr-flattened, so a multi-line
# message arrives exactly as typed whether the lock was free or not, and
# not raw, so a tab or newline inside the text itself can never be mistaken
# for the field separator or a second record. queue_flush splits each line
# on the first literal tab; base64's own alphabet contains neither.
queue_append() {
  local slug=$1 pid=$2 text=$3 fd
  exec {fd}>>"$TASKS/$slug/.send-queue.lock"
  flock "$fd"
  printf '%s\t%s\n' "$pid" "$(printf '%s' "$text" | base64 -w0)" \
    >>"$TASKS/$slug/send-queue"
  flock -u "$fd"
  exec {fd}>&-
}

# Durable queue for a cap-send delivery a busy task could not take. Guarded
# by its own lock, separate from the task lock, since this runs exactly
# when the caller could not get that lock.
queue_send() {
  local slug=$1 text=$2 id
  id=$(session_identity)
  queue_append "$slug" "${id%@*}" "$text"
}

# Ground truth for whether cap-send left a message queued for a task that
# has not gone in yet - a file's non-emptiness, not a word anyone chose.
# A holder killed mid-flush leaves the same backlog in send-queue.flushing
# instead, which queue_flush only folds back on its next call - until then
# it is exactly as pending as anything still in send-queue itself.
queue_pending() { [ -s "$TASKS/$1/send-queue" ] || [ -s "$TASKS/$1/send-queue.flushing" ]; }

# Prepends a file's lines onto a task's live spool, under queue_send's own
# lock, so nothing appended concurrently is lost or reordered behind
# content that was already there. On success the caller's file is spent
# and safe to remove; on failure (the swap itself could not be made) it
# returns 1 and leaves the file alone, so nothing is ever lost.
queue_prepend() {
  local slug=$1 f=$2 fd spool=$TASKS/$1/send-queue
  exec {fd}>>"$TASKS/$slug/.send-queue.lock"
  flock "$fd"
  { cat "$f" "$spool" 2>/dev/null || true; } >"$spool.recovering"
  if mv "$spool.recovering" "$spool" 2>/dev/null; then
    flock -u "$fd"
    exec {fd}>&-
    return 0
  fi
  rm -f "$spool.recovering"
  flock -u "$fd"
  exec {fd}>&-
  return 1
}

# Once a pane goes untrusted it stays that way for every process, not just
# this one: an unconfirmed pane_submit may have left text sitting unsent in
# the input box, and a later cap-send has no way to tell that apart from an
# empty one - typing into it merges the two and one Enter submits both. A
# marker on disk beside the queue survives past this process's own exit;
# only reviving the pane (a genuinely fresh input box) clears it.
queue_mark_untrusted() { : >"$TASKS/$1/.queue-untrusted"; }
queue_untrusted() { [ -f "$TASKS/$1/.queue-untrusted" ]; }
queue_clear_untrusted() { rm -f "$TASKS/$1/.queue-untrusted"; }

# Recovers a batch a holder killed mid-flush left behind in *.flushing,
# which nothing else ever reads back, by folding it in front of the live
# spool - only cap-send/task_try_lock ever call queue_flush for a given
# slug's lock, so nothing else can be claiming the same file right now.
# Returns 1 only when the fold itself could not be made; the batch stays
# on disk either way, never lost.
queue_recover_stranded() {
  local slug=$1 claimed=$TASKS/$1/send-queue.flushing
  [ -f "$claimed" ] || return 0
  if queue_prepend "$slug" "$claimed"; then
    rm -f "$claimed"
    return 0
  fi
  # queue_prepend already left $claimed on disk for the next attempt.
  # Claiming the live spool onto it would overwrite that undelivered
  # batch instead of recovering it - stop here and retry on the next flush.
  warn "$slug: could not recover queued messages in $claimed; left in place, will retry on the next flush"
  return 1
}

# Whether text can be typed into this pane right now, without causing any
# delivery itself: alive, and not sitting on a prompt herdr recognises.
# Digits can select a menu option and Enter can accept one, so typing a
# queued message into a blocked pane could approve something the captain
# never saw.
pane_usable() {
  agent_live "$1" || return 1
  [ "$(pane_agent_status "$1")" != blocked ]
}

# Claims the live spool for delivery by renaming it to *.flushing, so a
# concurrent queue_send keeps appending to a fresh send-queue rather than
# racing what this call is about to read. Returns 1 when the rename fails
# - nothing was there, or another process's claim won the race.
queue_claim() {
  local slug=$1 dir=$TASKS/$1 fd rc
  exec {fd}>>"$dir/.send-queue.lock"
  flock "$fd"
  mv "$dir/send-queue" "$dir/send-queue.flushing" 2>/dev/null
  rc=$?
  flock -u "$fd"
  exec {fd}>&-
  return "$rc"
}

# Drops the first line of a claimed batch. Called before that line is even
# attempted, not after: a kill during pane_submit itself leaves no way to
# tell whether the text went in, and the same never-retype invariant that
# drops a merely-unconfirmed delivery applies here too, so the line is gone
# from $1 before there is any chance of finding out. Nothing already popped
# can ever be found by queue_recover_stranded again.
queue_drop_claimed_line() {
  local claimed=$1 tmp=$1.tail
  tail -n +2 "$claimed" >"$tmp" 2>/dev/null || : >"$tmp"
  mv "$tmp" "$claimed"
}

# Delivers a claimed batch into the pane, in order, popping each line off
# $claimed before it is even attempted - a kill mid-submit is exactly as
# unrecoverable as a submit that types but never confirms, so both are
# treated the same way: gone, never retried. A confirmed failure stops the
# batch there as untrusted; anything still unclaimed stays in $claimed for
# queue_recover_stranded to fold back on a later flush.
queue_deliver_claimed() {
  local slug=$1 dir=$TASKS/$1 claimed=$TASKS/$1/send-queue.flushing
  local pid b64 text line

  while [ -s "$claimed" ]; do
    line=$(head -n1 "$claimed")
    queue_drop_claimed_line "$claimed"
    [ -n "$line" ] || continue
    pid=${line%%$'\t'*}
    b64=${line#*$'\t'}
    text=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
    if pane_submit "$slug" "$text"; then
      printf 'working: sent by %s: %s\n' "$(session_label "$pid")" "$(printf '%s' "$text" | tr '\n' ' ')" >>"$dir/status.log"
    else
      warn "$slug: a queued message from $(session_label "$pid") was typed but never confirmed; will not be retried - check by hand: cap peek $slug"
      printf 'unconfirmed: sent by %s: %s\n' "$(session_label "$pid")" "$(printf '%s' "$text" | tr '\n' ' ')" >>"$dir/status.log"
      queue_mark_untrusted "$slug"
      return 1
    fi
  done
  rm -f "$claimed"
}

# Delivers what queue_send queued into a live pane, in order, then clears
# the queue - called explicitly by cap-send before its own message, and
# automatically from every locking command's EXIT trap on release. Returns
# 0 only once the queue is empty, whether it started that way or ended
# that way; a non-zero return means something is left queued - the pane is
# untrusted, dead, blocked, or a claim could not be made or recovered.
queue_flush() {
  local slug=$1

  ! queue_untrusted "$slug" || return 1
  queue_recover_stranded "$slug" || return 1

  [ -s "$TASKS/$slug/send-queue" ] || return 0
  pane_usable "$slug" || return 1

  queue_claim "$slug" || return 0
  queue_deliver_claimed "$slug"
}
