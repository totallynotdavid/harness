Read `rules/code.md` and `rules/comments.md`, then reviewed `git diff fb2db4f..HEAD` (tree is clean, no uncommitted changes). `shellcheck -S warning` is clean on every changed script.

## Defects

**1. `cap send`'s 900s lock wait cannot do what it claims, and fails slower than the old refusal — `bin/cap-send:22-27`, `bin/lib.sh:305-317`**

The comment says the default "comfortably outlasts a cap-verify run (CAP_VERIFY_MAX, 900s by default)". `CAP_VERIFY_MAX` is a *per-script* ceiling: `capped` is invoked once per `run` (`bin/cap-verify:127,134`) and `run` is called in a loop over up to five scripts (`bin/cap-verify:206-209`). A verify run can hold the lock for ~75 minutes. `cap gate` and `cap gate --full` have no ceiling at all and hold the lock across one or two full review sessions.

Failure: captain runs `cap gate --full X`, then types `cap send X "stop, do Y"`. The send prints nothing for 15 minutes, then dies `X is still held by pid ... after waiting 900s`. The message is never delivered. Before this change it failed in a second. Worse, a captain running this through Claude Code's Bash tool cannot ever reach 900s — that tool's timeout maxes at 600s — so the wait is killed before it can succeed, leaving no message and no status line.

**2. The plain-shell identity fallback makes the user's terminal the owner — `bin/lib.sh:376-393`, `bin/hooks/crew-status.sh:23-28`**

`bin/cap:61` `exec`s the subcommand, so `$$` is the `cap` process and its parent is whatever shell the user typed in. With no `claude`/`codex` ancestor, `session_identity` returns `<login-shell-pid>@<stamp>`, and that shell stays alive for days.

Failure: user runs `cap spawn foo ...` in a terminal. `task.env` gets `CAP_OWNER=<shell pid>`. In the captain's Claude session, `cap gate foo` now dies with `foo is owned by pid NNNN`, and `crew-status.sh:26` skips `foo` from "Waiting on you" for as long as that terminal is open. No session owns `foo`; the guard blocks the only live one, and the hook that would have surfaced the task is silenced by the same field. The refusal deliberately does not mention `--take`, so the captain is left with a pid belonging to a shell and no route forward. `task_lock`'s own comment (`bin/lib.sh:328-332`) shows the fallback was already known to be unstable — pinning it in-process patches one symptom, not the cause. A plain shell should yield no owner, not a fake one.

**3. The guard protects the named task while the command mutates its descendants — `bin/cap-restack:34`, `bin/cap-land:20`, `bin/lib.sh:820-888`**

`stack_cascade` and `stack_cascade_landed` run `git rebase --onto` inside each descendant's worktree and `task_env_set` its record. Neither takes the child's `task_lock` nor calls `task_owner_claim` on it.

Failure: captain B runs `cap restack A`. Child task `B-child` is owned by live captain A and has an agent working in it. Its branch is rewritten and its `CAP_PARENT_TIP`/`CAP_BASE` overwritten with no refusal and no `--take` — the exact cross-session mutation this diff sets out to stop. It also races: `cap commit B-child` holds `B-child`'s lock while the cascade rebases underneath it, violating the "one cap command per task at a time" invariant `task_lock` documents.

**4. `cap verify`'s new usage strings document `--again` in a position the parser ignores — `bin/cap-verify:19,31` vs `:12`**

`--again` is only read when it is `$1`, before `--repo`/slug. Both new usage strings put it last. Reproduced:

```
cap verify foo --again        ->  slug=foo again=0 take=0
cap verify --repo p --again   ->  repo branch project=p again=0
```

Failure: `cap verify foo --again` leaves `again=0`, so `$progress` is not removed (`:52`) and every script hits `already_passed` and prints `=== ... === (passed earlier at this commit)` (`:119-122`). The user asking for a fresh run gets a no-op that reports all green. `--take` in that same position does work, so the line mixes a working flag with a silently dead one.

**5. `cap check` is the one locking command left outside the scheme — `bin/cap-check:11`, `bin/cap:22`**

It takes `task_lock` (so it can block `cap send` for the full 900s) but calls no `task_owner_claim` and offers no `--take`, so it runs unchallenged on another live session's task while every neighbour in the same help block refuses.

**6. `cap-spawn`'s existence checks still run outside the lock — `bin/cap-spawn:144-145` vs `:151`**

The comment at `:147-150` claims the flock serializes two racing spawns. It only does so while the winner is still running. If the winner completes inside the window between the loser's `[ -e "$dir" ]` check and its `task_lock`, the loser acquires the lock, overwrites `task.env` and `contract.md`, and opens a second pane. Re-checking `[ -e "$dir/task.env" ]` after acquiring the lock closes it.

## Comment rules

- `bin/cap-verify:14-17` narrates what the previous version did. `rules/comments.md` #13: state the current contract, not the history. The clause "silently dropped it in the --repo branch, which took a task nobody was going to own" also contradicts itself — dropping the flag cannot take a task.
- `bin/cap-send:24-26` states a number that is not a real constraint (#9), as shown in defect 1.
- `bin/lib.sh:328-332`, `bin/cap-spawn:296-298`, `bin/cap-send:57-58` and `bin/lib.sh:891-895` are four copies of the same warning that `CAP_ENV_SCRUB` is frozen and must not be read after a `CAP_*` export. Four comments defending a trap is the signal in #16 to change the code: delete the `CAP_ENV_SCRUB` global and have `cap-ask` call `cap_env_scrub` like the other two call sites, so the wrong path stops existing.

GATE: FAIL
