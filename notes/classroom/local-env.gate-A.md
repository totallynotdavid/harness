  $delta = time() - $lastcron;
  if ($delta > $expectedfrequency + MINSECS) {
      $status = result::WARNING;
      if ($delta > DAYSECS) {
          $status = result::CRITICAL;
      }

  Nothing in this stack schedules cron — dev-install.sh:62-69 says so explicitly and runs it exactly once, on a fresh install. On any later mise run check, dev:install takes
  the "already installed" early exit at dev-install.sh:41-43 and never runs cron, so $delta is at least the age of the last install. More than 120 s → exit 1; more than a
  day → exit 2. Either way set -e kills the task and mise run check fails with no output explaining why. The task that is supposed to be the health signal is red on a
  perfectly healthy stack.

  2. dev:reset deletes a production config.php that dev:install deliberately refuses to touch. .devstack/dev-reset.sh:13


  compose down -v
  rm -f "$REPO_ROOT/config.php"

  generate-config.sh:16-23 goes out of its way to detect exactly this case and abort:

  ▎ config.php already exists but its $CFG->wwwroot is not http://localhost. ... Refusing to touch it: move it aside yourself if you want the dev stack to generate its own.

❯ Read /home/dubu/git/captain/rules/code.md, then review every change in this worktree against master (git diff master, plus any uncommitted change). Report concrete defec…

  dev-reset.sh applies no such check. A developer who has .cicat/config.php.example filled in with live credentials sitting at the repo root — the precise scenario
  generate-config.sh guards against — loses it to mise run dev:reset. config.php is git-ignored (.gitignore:8), so there is no copy to recover from. The two scripts disagree
  about whether an unrecognised config.php is the dev stack's to destroy.



  3. The stale-schema recovery path can silently do nothing. .devstack/dev-install.sh:44-47

  elif [ "$schema_exit" -eq 1 ]; then
      echo "Installed schema does not match install.xml (a plugin or core upgrade is pending). Running admin/cli/upgrade.php..."
      "$DEVSTACK_DIR/dev-upgrade.sh"
      exit 0

  Exit 1 from check_database_schema.php means "the live schema differs from install.xml", which is not the same as "an upgrade is pending". When the mismatch comes from an
  install.xml edited without a version.php bump — the routine hazard in a repo whose job is merging vendor Moodle with local plugins — admin/cli/upgrade.php:163-165 takes
  this branch:

  if (!moodle_needs_upgrading(false)) {
      cli_error(get_string('cliupgradenoneed', 'core_admin', $newversion), 0);
  }

  cli_error with code 0 exits successfully. dev-upgrade.sh returns 0, dev-install.sh reaches its exit 0, and the developer is told the upgrade ran while the schema is still
  wrong. Nothing re-runs check_database_schema.php afterwards to confirm the fix landed. LOCAL-ENV.md:32-38 sells this path as "runs admin/cli/upgrade.php automatically ...
  instead of dead-ending"; in this case it dead-ends quietly.

  4. Two clones or worktrees of this repo share one stack. .devstack/lib.sh:34

  compose() {
      (cd "$DEVSTACK_DIR" && $COMPOSE "$@")
  }

  Compose derives the project name from the directory it runs in, which is always devstack. Every clone and every git worktree of this repository therefore resolves to the
  same project: the same devstack_db-data and devstack_moodledata volumes and the same container names. Running mise run dev in a second worktree does not stand up a second
  stack — it recreates the existing containers (the bind mount source changed) against the other tree's database. This repo is worked on in worktrees; you are reviewing from
  one now. Setting an explicit project name derived from $REPO_ROOT, or accepting the collision in writing, would settle it.

  Lower severity

  - .devstack/nginx/default.conf.template:21-29 — the \.php(/|$) location has no try_files $uri =404, so every .php-suffixed URI is forwarded to php-fpm whether or not the
    file exists. Not exploitable here (Moodle keeps no user uploads inside the docroot, and php-fpm answers "Primary script unknown"), and the listener is loopback-only, but
    it is the one place in the stack where a boundary goes unvalidated.
  - .devstack/render-test-certificate.php:190 hardcodes $CFG->dataroot . '/temp/' rather than $CFG->tempdir. install_init_dataroot() (lib/installlib.php:108-112) creates
    that directory, so it works today; if it ever does not, the failure surfaces as the misleading could not write the full PDF to ....

  Not verified by execution: I did not stand the stack up or run check:certificate, because doing so writes config.php into the worktree and creates databases — outside a
  read-only review. Findings 1–3 are read off the code paths quoted above.

  GATE: FAIL

✻ Worked for 9m 7s · done 4:40 PM

─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Opus 5  |  ctx 12% used  88% left  |  in:117779 out:3  |  5h:23% 7d:19%                                                                                               /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
