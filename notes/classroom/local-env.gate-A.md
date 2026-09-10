I'll start by reading the rules file and getting an overview of the changes.
Diff against `master` is empty — this branch's work is already merged there (identical trees). Reviewing the branch's actual contribution (`ea3ecec2..HEAD`) instead.
I accidentally stopped your running dev stack with that `dev:down` probe. Restoring it now.
`git diff master` is empty — this branch's tree is byte-identical to `master` (`fe16f9a7` both); the work landed there already as `ea3ecec2..41477d00`. Worktree clean. I reviewed that range instead: 23 files, +1770/-7.

Side effect I caused: a `mise run dev:down` probe stopped your running stack. Restarted it with `mise run dev`; `mise run check` then passed end to end (schema OK, all status checks OK, certificate rendered on 1 line, 1 embedded image).

## Defects

**1. `.devstack/generate-config.sh:213` — the strip-drift guard cannot detect the drift it exists for.**

The comment says a reworded `config.php.example` makes the strip "silently no-op … Fail loudly instead." The check greps `$TMP_FILE` for the *same* stale `STRIP_LINES` text. When the example is reworded, the stale text is absent from the output, so the guard passes and the new production-only prose ships. It only ever catches the strip pipeline itself breaking while wording is unchanged.

Reproduced against a scratch copy with one word changed (`tighter` → `safer`) in `.cicat/config.php.example:33`:

```
=== running generate-config.sh against the reworded example ===
Wrote .../driftdemo/config.php
rc=0
=== production-only prose in the generated config.php: ===
30:// Production currently uses 0777. 02770 (setgid, no world access) is safer
```

Failure: every generated dev `config.php` carries production-only prose — including `.cicat/config.php.example:27-29`, which names the production docroot and asserts `dataroot` is a sibling of it, a statement that is false for the dev config's `/var/www/moodledata`. Silent, and permanent, since the "already exists" branch never regenerates.

**2. `.devstack/nginx/default.conf.template:19` — the deny list omits `.cicat/`.**

```
/.git/config                                         404 text/html
/.devstack/render-test-certificate.php               404 text/html
/.cicat/DEPLOY.md                                    200 application/octet-stream
```

`DEPLOY.md` carries the production hostname `srv1694816.hstgr.cloud`, the deploy account names, `DEPLOY_PATH`, and the note that the server's `.git` is currently unprotected. Loopback-only binding keeps the practical risk low, but `.cicat` is the one dot-directory in this repo with operational detail in it, and `.cicat/LOCAL-ENV.md:102` states the deny list covers "`config.php`, `.git`, `.env` and `.devstack/`" without noting the gap. `DEPLOY.md:115-119` recommends a blanket `location ~ /\.` for the production alternative; the dev stack enumerates instead.

**3. `.devstack/nginx/default.conf.template:39` — missing static assets return the homepage, not 404.**

```
missing-asset: 200 text/html; charset=utf-8 22423 bytes   (/theme/image/does-not-exist.png)
missing-dir:   200 text/html; charset=utf-8 22423 bytes   (/no/such/path)
```

`try_files $uri $uri/ /index.php?$args` sends every unmatched non-PHP URI to Moodle's front page. A broken asset URL reads as a working request during development. Moodle needs the front-controller fallback for nothing here — `=404` is the correct terminal.

**4. `.devstack/generate-config.sh:70-76` — `HTTP_PORT` drift undetected when `wwwroot` has no port.**

A hand-edited `wwwroot` of exactly `http://localhost` still passes `config_is_ours`, leaves `existing_port` empty, skips the comparison, and the script reports "config.php already exists, leaving it as is" (exit 0). nginx then listens on `$HTTP_PORT` while `initialise_fullme()` works from a portless `wwwroot`. The comment acknowledges the skip but not that it lands in a broken state that nothing reports.

**5. `.devstack/render-test-certificate.php:534, 553` — `$linecount` is a constant by construction.**

Any value `> 1` calls `fail()` two lines earlier, so the returned `$linecount` is always `1` and the report line is `autofitname rendered on 1 line(s)` unconditionally. Threading it through the return tuple is ceremony (`rules/code.md`: "Remove dead code … and ceremony without active value").

**6. `.devstack/render-test-certificate.php:481-482` — paired magnitudes, one named and one not.**

`$SCAN_SAFETY_PT = 10.0` is named; the `5.0` in `$scantoppt = $expectedtoppt - 5.0` on the adjacent line is bare. Both bound the same scan window.

## Verified sound

`fastcgi_split_path_info` + `set $path_info` ordering (slasharguments return 200: `/theme/image.php/boost/core/1/i/edit`, `/lib/requirejs.php/-1/core/first.js`); `check_database_schema.php` exit codes 0/1/2 match `admin/cli/check_database_schema.php:56,64,76`; `schema_says_disconnected` matches real output (reproduced with a wrong password — `!!! <p>Error: Database connection failed</p>`, exit 1); `own_nginx_running` matches podman-compose's `_`-separated names; mise runs tasks from config root, so the relative `bash .devstack/*.sh` paths hold from subdirectories; `--` arg passing works for `dev:php`; the six tracked `config.php` files and four vendored `.github/` directories in `DEPLOY.md:88-105` are accurate; the four TCPDF font definitions exist; `shellcheck -x` is clean apart from SC1091/SC2016 info noise.

GATE: FAIL
