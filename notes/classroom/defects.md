# classroom: known defects

Defects in the classroom project itself. A defect in Captain belongs in
`paper-cuts.md`; this file is the other side of that boundary.

Each entry names the file, what is wrong, and the failure it causes. The next
task on this project should read this before starting.

## Open, found after the code landed

The local-env dev stack landed on `master` as `ea3ecec2..41477d00` before a
gate ever passed on it. A Gate A review run afterwards found six defects in
that range. They are recorded here rather than in a gate report because the
report describes a branch that no longer has anything to land, and nothing
reads a gate report back. Full text: `notes/classroom/local-env.gate-A.md`.

- [ ] `.devstack/generate-config.sh:213` - the strip-drift guard cannot detect
  the drift it exists for. It greps the generated file for the same stale
  `STRIP_LINES` text it is meant to notice the absence of, so a reworded
  `.cicat/config.php.example` passes the guard and ships production-only prose
  into every dev `config.php`. Reproduced by changing one word in the example.
  The generated config then carries the production docroot and asserts
  `dataroot` is a sibling of it, which is false for the dev `/var/www/moodledata`.
  The "already exists" branch never regenerates, so it is permanent once written.

- [ ] `.devstack/nginx/default.conf.template:19` - the deny list omits
  `.cicat/`. `/.cicat/DEPLOY.md` returns 200 while `/.git/config` and
  `/.devstack/` correctly return 404. `DEPLOY.md` carries the production
  hostname, the deploy account names, `DEPLOY_PATH`, and the note that the
  server's `.git` is unprotected. Loopback-only binding keeps the practical
  risk low. `.cicat/LOCAL-ENV.md:102` claims the deny list already covers this.

- [ ] `.devstack/nginx/default.conf.template:39` - `try_files $uri $uri/
  /index.php?$args` sends every unmatched non-PHP URI to Moodle's front page,
  so a missing asset returns 200 and 22423 bytes of homepage. A broken asset
  URL reads as a working request during development. `=404` is the right
  terminal here; Moodle needs the front-controller fallback for nothing.

- [ ] `.devstack/generate-config.sh:70-76` - `HTTP_PORT` drift goes undetected
  when `wwwroot` carries no port. A hand-edited `wwwroot` of exactly
  `http://localhost` passes `config_is_ours`, leaves `existing_port` empty,
  skips the comparison, and exits 0 saying the config was left alone. nginx
  then listens on `$HTTP_PORT` while `initialise_fullme()` works from a
  portless `wwwroot`.

- [ ] `.devstack/render-test-certificate.php:534,553` - `$linecount` is a
  constant by construction. Any value above 1 calls `fail()` two lines
  earlier, so the report line always reads `rendered on 1 line(s)`. Threading
  it through the return tuple is ceremony.

- [ ] `.devstack/render-test-certificate.php:481-482` - paired magnitudes, one
  named and one not. `$SCAN_SAFETY_PT = 10.0` is named; the bare `5.0` in
  `$scantoppt = $expectedtoppt - 5.0` on the next line bounds the same scan
  window.

## Verified sound in the same review

Recorded so a later pass does not re-derive them: `fastcgi_split_path_info`
and `set $path_info` ordering (slasharguments return 200),
`check_database_schema.php` exit codes 0/1/2, `schema_says_disconnected`
against a real wrong-password failure, `own_nginx_running` against
podman-compose's naming, mise running tasks from the config root, `--` arg
passing for `dev:php`, the tracked `config.php` and vendored `.github/` lists
in `DEPLOY.md:88-105`, and the four TCPDF font definitions.
