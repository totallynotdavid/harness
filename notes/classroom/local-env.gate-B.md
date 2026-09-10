
  .devstack/dev-install.sh:56-64:
  elif [ "$schema_exit" -eq 1 ]; then
      echo "Installed schema does not match install.xml ... Running admin/cli/upgrade.php..."
      "$DEVSTACK_DIR/dev-upgrade.sh"
      ...
  This call is not wrapped in any set +e/diagnosis, unlike every other failure branch in the same file (the dbconnectionfailed check at lines 44-54, and the post-upgrade
  stale-schema check at lines 66-79, both of which print contextual, actionable guidance). If admin/cli/upgrade.php itself fails, set -euo pipefail aborts dev-install.sh
  immediately and the user gets only the raw Moodle exception, with no message about what happened or how to recover — breaking the pattern the rest of this exact function
  otherwise follows carefully (code.md: "Validate at boundaries and return explicit errors with actionable context").

  I reproduced this live: a real mise run dev:install in this worktree hit
  !!! Site is being upgraded, please retry later. !!!
  Error code: upgraderunning
  (Moodle's own upgraderunning lock in lib/setup.php:786-792, set by an earlier interrupted upgrade run in this worktree) and aborted with nothing but that raw dump. A
  second run, once the 5-minute lock window (lib/upgradelib.php:1571) expired, succeeded end-to-end (install, upgrade, cron all completed). So the failure is self-healing,
  but nothing in the script or .cicat/LOCAL-ENV.md says so — a developer who Ctrl-C's a slow dev:install, or re-runs it too soon after an interrupted one, hits an
  unexplained crash.

  Defect 2 — uncommitted regression currently sitting in .gitignore

  The working tree (in scope per "plus any uncommitted change") currently has an uncommitted edit to .gitignore that re-adds the
  # =============================================================================
  # CICAT Aula Virtual — Moodle deployment repository
  #
  ...
  # =============================================================================
  banner header — the exact redundant ceremony this branch's own committed diff (part of the local-dev-stack work) deliberately removed. If committed as-is, it silently
  reverts that cleanup (code.md: "Remove dead code, commented-out code, and ceremony without active value").

  (Two other uncommitted edits in the tree — .devstack/lib.sh adding required-env-var guards, and .devstack/render-test-certificate.php de-duplicating the hardcoded fontsize
  into AUTOFITNAME_STARTSIZE and splitting the pdfimages exit-code check from the image-count check — are genuine improvements with no defects found.)

  Everything else checked out

  I verified, against actual source (not assumption), every non-obvious claim the diff makes: the sed/sanitized regexes in generate-config.sh against the real
  .cicat/config.php.example byte-for-byte; the mod_customcert element behavior (cargogrupo, date, autofitname) against their real render() code; the local_certengine
  resolver's title/name precedence against the fixture it seeds; the rsync exclude-anchoring claims in DEPLOY.md against deploy.yml; the PHP 8.2 minimum claim against
  admin/environment.xml and this tree's actual version.php (5.0.4); and the official php:8.2-fpm-bookworm image's WorkingDir (confirmed /var/www/html, which the
  relative-path php_exec calls depend on). All of it was accurate.

  GATE: FAIL

✻ Baked for 10m 8s · done 9:04 AM

─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  Sonnet 5  |  ctx 16% used  84% left  |  in:164180 out:3  |  5h:82% 7d:42%                                                                                             /rc
  ⏵⏵ bypass permissions on (shift+tab to cycle) · 1 memory recalled · ← for agents
