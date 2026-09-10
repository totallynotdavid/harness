## gate A (opus)

Full text from the reviewer's own transcript.

Read `/home/dubu/git/captain/rules/code.md`. Reviewed `git diff master` (4 files) plus the untracked `mise.toml`, `.cicat/LOCAL-ENV.md` and `.devstack/` (17 files).

Verified working: `generate-config.sh` produces a correct `config.php` from the current `.cicat/config.php.example` (ran the real script against a scratch copy — exit 0, all 13 verification patterns matched); mise runs tasks from the config root and passes `--` args through (tested both); `bash -n` and shellcheck clean; DEPLOY.md's factual claims check out (`git ls-files` confirms exactly those six `config.php` files and those four vendored `.github/` dirs, and no tracked `.well-known/`, `.user.ini`, `.htaccess`, `error_log` or `*.log`); `check_database_schema.php` really does exit 0/1/2 as `dev-install.sh` assumes; the customcert font naming round-trips through `element_helper::get_font()` back to the real font files.

## Defects

**1. `check:certificate` renders in preview mode, disabling the code paths it exists to guard.**
`.devstack/render-test-certificate.php:239` calls `$template->generate_pdf(true, $admin->id, true)` — the first argument is `$preview`.

- `mod/customcert/element/cargogrupo/classes/element.php:66` gates its entire distinguishing branch on `if (!$preview && !empty($info->groupname))`. With `$preview = true` the element degrades to the stock `text` element. A regression that broke the group lookup passes this check.
- `mod/customcert/element/date/classes/element.php:159-161`: `if ($preview) { $date = time(); }` skips the page → customcert → issue lookup entirely.

`$preview = false` would work here: the script uses `dateitem = -5` (`CUSTOMCERT_DATE_CURRENT_DATE`), which never dereferences the `$issue` record that `get_record(...)` returns as `false` on a site with no issues. The weakening is unforced.

**2. Same file, lines 227-229: `cargogrupo` is seeded with `'groupname' => '', 'textingroup' => ''`.** Even at `$preview = false`, `!empty($info->groupname)` is false, so the branch is unreachable. The element is only ever exercised as a font carrier.

**3. Line 226: `autofitname` is added with the default `$width = 0`.** Its only distinguishing logic is `mod/customcert/element/autofitname/classes/element.php:31`, `if ($width > 0) { while (GetStringWidth(...) > $width && $fontsize > 5) ... }`. At width 0 the shrink loop never runs. `ceasset` is the only element given a non-zero width (`30`).

**4. Consequence — `.cicat/LOCAL-ENV.md:209-215` claims coverage the script does not have:** "This is what stays a guard on every future change to `mod_customcert`, its four CICAT elements, or the four custom TCPDF fonts." Only two of the four elements are asserted: `cetext` (body text via `pdftotext`) and `ceasset` (embedded image count). `autofitname` and `cargogrupo` output is never checked — either can render nothing and the check still exits 0. The four fonts are covered only incidentally, by TCPDF throwing on a missing font definition file.

**5. `.devstack/generate-config.sh:26-30` guards `HTTP_PORT` drift but not `DB_NAME`/`DB_USER`/`DB_PASSWORD` drift.** `.env.example:10-12` and `LOCAL-ENV.md:118-119` both state all four are baked into `config.php` at generation time. Edit `DB_PASSWORD` and run `mise run dev`: the port still matches, so `config_is_ours` short-circuits at line 31 and leaves the old `config.php`; MariaDB skips re-initialisation on an existing volume, so the old password still works. `.env` now describes a state nothing is using, silently. The elaborate `schema_says_disconnected` diagnostic in `dev-install.sh:45-53` only fires in the narrower case where `config.php` was regenerated against a stale volume.

**6. `.devstack/generate-config.sh:28` prescribes a destructive fix for a non-destructive problem.** On a port mismatch it directs the user to `mise run dev:reset` then `mise run dev` — which destroys `db-data` and `moodledata`, i.e. the whole local site and any seeded content. `LOCAL-ENV.md:145-147` itself notes `HTTP_PORT` has no volume-persistence problem. Deleting `config.php` and re-running `dev` regenerates it against the existing database; that path is never offered.

## Reuse / duplication (rules: keep one source of truth)

**7. `.devstack/docker-compose.yml:32-44`** — the `cron` service copies `php`'s `build.context`, `build.args`, `depends_on` and both `volumes` verbatim. These have a shared reason to change (they must run the same image against the same tree); a YAML anchor or `extends` removes the drift risk.

**8. `.devstack/dev-check.sh:12` and `.devstack/dev-check-certificate.sh:8`** repeat the same 130-character hint string literally. `lib.sh` already owns the default hint; this one belongs beside it.

**9. `mise.toml:9-14`** re-implements the `set -a` / source-`.env` block that `lib.sh:13-16` already owns, hardcoding the `.devstack/.env` path a second time.

## Gap

**10. Nothing in the repository records the production runtime.** `.env.example:13` pins `PHP_VERSION=8.2` (Moodle 5.0's *minimum*, per `admin/environment.xml:4724`) and `docker-compose.yml:3` pins `mariadb:11.4.13`. `.cicat/DEPLOY.md:136-137` says aaPanel owns the PHP-FPM pool and MariaDB instance but never states their versions, so `mise run check` can green-light a runtime with no stated relationship to the deploy target.

GATE: FAIL
