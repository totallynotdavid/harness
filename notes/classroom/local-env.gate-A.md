I'll start by reading the rules file and getting an overview of the diff.
Reviewed `git diff master` (23 files, +1705/-11); working tree is clean, so committed state is the whole change.

## Defects

**1. `.devstack/generate-config.sh:112-113` — a missing or misspelled `.env` line dies with an error that names neither the variable nor the file.**

`${!var}` under `set -u` fails on the indirection itself. Reproduced with a `.env` that lacks `HTTP_PORT`:

```
.devstack/generate-config.sh: line 113: !var: unbound variable
exit=1
```

`mise run dev` stops there with no mention of `HTTP_PORT` or `.devstack/.env`. The same expansion at line 59 fails the same way on the drift path. `.cicat/LOCAL-ENV.md` states the opposite: *"`docker-compose.yml` reads every variable from it as required (`${VAR:?...}`), so a deleted or misspelled line fails the task instead of silently falling back"* — those `:?` messages are unreachable for `HTTP_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`, because `generate-config.sh` runs before `compose up`. `PHP_VERSION` has the same problem one step later at `dev-install.sh:20` (`${PHP_VERSION}` under `set -u`), so its compose message is unreachable too.

**2. `.devstack/generate-config.sh:165` — `\n` in the sed replacement is a GNU extension, and the verification block provably cannot catch the non-GNU result.**

Under a POSIX/BSD `sed` (macOS host — the docs require only mise plus a container engine, they do not restrict the host OS), `\n` yields a literal `n` and the three settings land on one line. Simulated that output and ran the script's own checks against it:

```
38:$CFG->debug = 32767;n$CFG->debugdisplay = 1;nnrequire_once(__DIR__ . '/lib/setup.php');
--- verification greps that generate-config.sh runs ---
PASS: \$CFG->debug[[:space:]]*=[[:space:]]*32767;
PASS: unset\(\$CFG\);
PASS: global \$CFG;
PASS: \$CFG = new stdClass\(\);
--- is it valid PHP? ---
Parse error: syntax error, unexpected variable "$CFG" in /s/bsdlike.php on line 38
```

Every check passes, so `mv "$TMP_FILE" "$CONFIG_FILE"` installs a config that fatals on every request and every CLI task — and the "already exists, leaving it as is" short-circuit at line 88 means it is silently reused on every later run. That is the exact failure the comment at lines 116-118 says the temp-file-and-verify step exists to prevent. (Positive control: with GNU sed the pipeline produces valid PHP — `php -l` clean.)

**3. `.devstack/render-test-certificate.php:397` — a `pdfimages` failure is reported as a `ceasset` regression.**

```php
if ($pdfimagesrc !== 0 || $embeddedimages < 1) {
    fail('rendered PDF has no embedded images; ceasset may be silently rendering nothing (its signature image never got embedded).');
}
```

If poppler-utils is missing or `pdfimages` cannot read the file, `$pdfimagesrc` is non-zero and the operator is told the certificate element is broken. The two sibling extractors get this right — `extract_pdf_text()` and `assert_autofitname()` both check the exit code separately and say `"pdftotext exited $rc"`. Only this one conflates tool failure with element failure.

**4. `.devstack/render-test-certificate.php:45, 69, 144` — `AUTOFITNAME_STARTSIZE` is not the size the element is actually created at.**

`add_element()` hardcodes `'fontsize' => 20` (line 69); the width probe measures at `AUTOFITNAME_STARTSIZE` (line 144) and the failure message quotes it (line 525). They agree only by coincidence today. Change the constant and the probe measures at one size while the element still renders at 20, so `$autofitnamewidthmm` no longer bears the intended relation to the shrink loop's stopping condition — the one-line assertion becomes either meaningless or a spurious failure, with nothing saying so. Same class of silent divergence the file guards against elsewhere.

## Smaller

- `.gitignore`: the diff deletes the file's title banner (`# CICAT Aula Virtual — Moodle deployment repository` and its two rule lines) alongside the additions this change needs. Unrelated to adding the dev-stack ignores.
- `.devstack/dev-php.sh`: `mise run dev:php` with no arguments runs `php` with no script inside the container, which blocks reading stdin with no message. The task description documents the `-- script.php` form but nothing enforces it.

## Verified sound

Compose file renders correctly under this host's podman-compose (`$$` → `$` for `NGINX_ENVSUBST_FILTER`, merge key expands, ports/volumes as intended); compose detection correctly rejects this host's non-functional WSL Docker shim and falls through to podman-compose; `own_nginx_running`'s `[_-]` regex matches podman-compose's `_` separator and honours `COMPOSE_PROJECT_NAME`; mise appends `--` args and runs from the config root; all shell scripts pass `bash -n` and `shellcheck -x`; the certificate script passes `php -l`; every Moodle CLI flag used exists; `check_database_schema.php` really does exit 0/1/2 as assumed; `dateitem '-5'` really is `CUSTOMCERT_DATE_CURRENT_DATE` and its branch never dereferences the issue record; customcert's `_b` font-name split round-trips to the real font files (`scriptmtb` → family `scriptmt` + style `B` → `scriptmtb.php`); `element_helper::render_content` zeroes cell padding, so the autofitname one-line assertion has the slack it needs; all five persistent classes' required properties are supplied. DEPLOY.md's factual claims check out exactly: six tracked `config.php` files, four vendored `.github/` directories, PHP 8.2.0 and MariaDB 10.11.0 as Moodle 5.0's documented minimums, tree at 5.0.4.

GATE: FAIL
