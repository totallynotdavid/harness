# shellcheck shell=bash

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
# Takes no lock and releases none: the caller holds the child's lock across
# every field it and stack_cascade_delivered rewrite, and releases it once that
# whole pass is done. Checks task_owner_free rather than claiming ownership,
# since the cascading session is not this descendant's owner. Returns 2 for
# an owned-elsewhere descendant, distinct from a rebase conflict (1), so the
# caller skips flushing work nobody here did.
stack_sync_task() {
  local task=$1 new_tip=$2 snap=$3
  local tree branch old_tip

  if ! task_owner_free "$task"; then
    STACK_CONFLICT=$task
    warn "$task is owned by pid $(task_field "$task" CAP_OWNER 2>/dev/null | cut -d@ -f1); its branch was left where it was"
    return 2
  fi

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

# Locks each child before stack_sync_task touches it and releases it exactly
# once when this pass on that child is done, on every path: a locked-out
# child is never touched at all, an owned-elsewhere child (stack_sync_task
# returns 2) gets a bare task_unlock since no work was done on it, and every
# other outcome - rebase conflict or success, including the recursive call
# below - gets task_release since this session did work under that lock.
stack_cascade() {
  local slug=$1 new_tip=$2 snap=$3
  local child tree rc sync_rc

  for child in $(task_children "$slug"); do
    if ! task_try_lock "$child"; then
      STACK_CONFLICT=$child
      warn "$child is locked by another cap command; its branch was left where it was"
      return 1
    fi

    sync_rc=0
    stack_sync_task "$child" "$new_tip" "$snap" || sync_rc=$?
    if [ "$sync_rc" = 2 ]; then
      task_unlock "$child"
      return 1
    elif [ "$sync_rc" != 0 ]; then
      task_release "$child"
      return 1
    fi

    tree=$(task_field "$child" CAP_TREE)
    rc=0
    stack_cascade "$child" "$(git -C "$tree" rev-parse HEAD)" "$snap" || rc=$?
    task_release "$child"
    [ "$rc" = 0 ] || return "$rc"
  done
}

# After a parent is delivered, descendants inherit its base and PR target. Same
# lock discipline as stack_cascade: one task_try_lock per child, released
# exactly once by whichever exit the child's pass takes.
stack_cascade_delivered() {
  local slug=$1 new_tip=$2 snap=$3
  local child tree up_base up_parent pr rc sync_rc

  up_base=$(task_field "$slug" CAP_BASE)
  up_parent=$(task_field "$slug" CAP_PARENT)

  for child in $(task_children "$slug"); do
    if ! task_try_lock "$child"; then
      STACK_CONFLICT=$child
      warn "$child is locked by another cap command; its branch was left where it was"
      return 1
    fi

    sync_rc=0
    stack_sync_task "$child" "$new_tip" "$snap" || sync_rc=$?
    if [ "$sync_rc" = 2 ]; then
      task_unlock "$child"
      return 1
    elif [ "$sync_rc" != 0 ]; then
      task_release "$child"
      return 1
    fi

    stack_snapshot_field "$snap" "$child" CAP_BASE
    task_env_set "$child" CAP_BASE "$up_base"
    stack_snapshot_field "$snap" "$child" CAP_PARENT
    task_env_set "$child" CAP_PARENT "$up_parent"

    pr=$(task_field "$child" CAP_PR)
    if [ -n "$pr" ]; then
      gh pr edit "$pr" --base "$up_base" >/dev/null ||
        warn "could not retarget $pr to $up_base; set its base by hand"
    fi

    tree=$(task_field "$child" CAP_TREE)
    rc=0
    stack_cascade "$child" "$(git -C "$tree" rev-parse HEAD)" "$snap" || rc=$?
    task_release "$child"
    [ "$rc" = 0 ] || return "$rc"
  done
}
