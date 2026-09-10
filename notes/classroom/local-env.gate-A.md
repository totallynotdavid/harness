## gate A (opus)

Recovered from the reviewer's own transcript; the pane capture
lost findings 1 to 3 off the top.

## Confirmed defects

**1. `.devstack/dev-install.sh:45-47` — the connection-failure guard can never fire.**

```bash
schema_says_disconnected() {
    printf '%s' "$1" | grep -q 'dbconnectionfailed'
}
```

`dbconnectionfailed` is a lang-string *key*, not output. On a DB connection failure `setup_DB()` (`lib/dmllib.php:344`) rethrows `dml_connection_exception`, `default_exception_handler` reaches `bootstrap_renderer::early_error`, and the CLI branch (`lib/classes/output/bootstrap_renderer.php:179-189`) prints:

```php
if (CLI_SCRIPT) {
    echo "!!! $message !!!\n";
```

`$message` is the resolved string from `lang/en/error.php:204`:

```
$string['dbconnectionfailed'] = '<p>Error: Database connection failed</p>
```

The `$errorcode` argument is used only in the AJAX branch. So stdout carries `!!! <p>Error: Database connection failed</p>… !!!` and never the token being grepped for. `default_exception_handler` then `exit(1)` (`lib/setuplib.php:202`).

Failure: the exact scenario `dev-install.sh:50` and `.cicat/LOCAL-ENV.md:54-62` exist to diagnose — `.devstack/.env` credentials edited without `dev:reset`, so `config.php` and the MariaDB volume disagree — falls through to the `schema_exit -eq 1` branch instead. The user is told *"Installed schema does not match install.xml (a plugin or core upgrade is pending). Running admin/cli/upgrade.php…"*, upgrade.php then fails to connect too, and `set -e` aborts. The diagnosis is the opposite of correct. Same bug at line 67 for the post-upgrade re-check. A match on `Error: Database connection failed` would work.

**2. `.devstack/generate-config.sh:87` — `tail -n +6` is an unguarded magic offset, and both verification blocks miss it.**

The comments at lines 100-105 and 137-140 claim a reformatted `.cicat/config.php.example` breaks the script loudly. It does not, because neither guard covers the positional strip. Simulated with one line added to the example's header:

```
### grow header by 1 line -> tail -n +6 output starts at:
// NEW production-only note added later.

unset($CFG);
```

That line is not in `STRIP_LINES`, so `grep -vFx` leaves it, and the survivor check at line 141 passes. Simulating a two-line-shorter header through the full pipeline:

```
missing: <none>  (exit-would-be: PASS)
strip-check: PASS
--- does output still contain unset($CFG)? ---
0
```

Both guards report success while `unset($CFG);` has been silently swallowed. Three lines shorter also drops `global $CFG;`; four drops `$CFG = new stdClass();`, which makes every following `$CFG->…` a fatal on null. The `expected` map (lines 111-122) only checks settings that *are* present; nothing asserts that the structural lines survived, or that the header length is what line 87 assumes.

**3. `mise.toml:40` — `check` does not fan out to `check:certificate`.**

```toml
[tasks.check]
depends = ["dev"]
```

Verified that mise has no implicit colon fan-out: a parent `check` with a `check:child` runs only `PARENT-RAN`. `.cicat/LOCAL-ENV.md:196-199` justifies the certificate render as "the only proof in this repository that the certificate pipeline still renders, so it runs as its own task rather than a script someone has to remember to invoke" — but as wired, `mise run check` (and therefore `cap verify`, which looks for the task named exactly `check`) never runs it. It remains exactly the thing someone has to remember to invoke.

**4. `.cicat/DEPLOY.md:86` — blanket claim that is false for most of the list.**

> `deploy.yml`'s excludes are anchored to the repository root with a leading `/`.

Four of the eleven are (`/.devstack/`, `/mise.toml`, `/config.php`, `/.cicat/LOCAL-ENV.md`). `.git/`, `.github/`, `.well-known/`, `certificados_sin_firma/`, `.user.ini`, `.htaccess`, `error_log` and `*.log` are not. `.github/` is not hypothetical — it matches five tracked directories inside core/plugins:

```
availability/condition/role/.github/workflows/…
filter/generico/.github/workflows/ci.yml
mod/customcert/.github/workflows/moodle-ci.yml
theme/adaptable/.github/ISSUE_TEMPLATE/…
theme/adaptable/.github/workflows/ci.yml
```

The content is benign, but the doc is what a reader consults before a production deploy, and it asserts a property the workflow does not have. (The six-file `config.php` claim at lines 88-92 *is* correct — `git ls-files` returns exactly those six.)

**5. `.devstack/generate-config.sh:17-21` + `dev-install.sh:15` — `HTTP_PORT` drift is undetected, unlike DB drift.**

`generate-config.sh` short-circuits on any existing `config.php` whose wwwroot starts with `http://localhost`, regardless of port. `dev-install.sh` then port-checks and binds the *new* `HTTP_PORT`, and nginx listens on it. `config.php` still carries the old one. `initialise_fullme()` (`lib/setuplib.php:694`) redirects the browser to `$CFG->wwwroot` with the "Incorrect access detected" message — i.e. to the old port, where nothing is listening. Connection refused, with nothing naming the cause. `.devstack/.env.example:8-12` documents that `dev:reset` is required, and the DB-drift case got explicit detection and a named fix; the port case, which is equally detectable here (compare `$HTTP_PORT` against the wwwroot in `config.php`), gets neither.

## Lower severity

**6. `README.md:76-78` overstates the guard.**

> every tool in `.devstack/` that touches `config.php` checks for `http://localhost` first and refuses to run against anything else

`config_is_ours` is called by exactly two scripts (`generate-config.sh:18`, `dev-reset.sh:17`). `render-test-certificate.php:14` requires `config.php` and then creates a course, a customcert instance and `local_certengine` cargo/variant/asset/slot/rule/participant rows in whatever database that config points at, with no wwwroot check.

**7. `.github/workflows/deploy.yml:65` — `--exclude='/.cicat/LOCAL-ENV.md'` has no active value.** Every other `.cicat/*.md` still deploys; the file is prose, and the things that actually must not reach the docroot (`/.devstack/`, `/mise.toml`) are already excluded on lines 62-63. It is one more line a reviewer of the exclude list has to reason about.

**8. `.devstack/render-test-certificate.php:127-175` — the fixture seed is not repairable.** `$sigid`, the `local_certengine_slot` row and the `rule` are created inside `if (!$variant)`. A run interrupted after `$variant->create()` leaves the variant present and the asset/slot/rule missing; every later run skips the whole block and dies at line 275 with *"rendered PDF has no embedded images; ceasset may be silently rendering nothing"* — a rendering diagnosis for what is actually missing seed data, with no path back except manual DB edits.

**9. `.gitignore:1-4` — the reflowed header dropped an instruction, not just ceremony.** The removed banner ended with "Do not un-anchor these."; the replacement explains the reasoning but no longer states the rule. Reflowing the header at all is outside what this branch needed (it needed lines 9-14), and it enlarges the diff a reviewer has to read.

GATE: FAIL
