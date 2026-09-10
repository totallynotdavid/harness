## gate A (opus)

Recovered from the reviewer's own session transcript: the pane capture
lost finding 1 and the heading of finding 2 off the top.

Reviewed `git diff master` plus the untracked `.devstack/`, `mise.toml`, `.cicat/LOCAL-ENV.md`. Verified against a live run of the stack (podman-compose, project `devstack-local-env-1711220984`): `mise run check` and `mise run check:certificate` both pass, the site serves on `127.0.0.1:8080`, and the deny rules 404 `/config.php`, `/.devstack/*`, `/.git/config`.

Defects found:

**1. `generate-config.sh` leaves `HTTP_PORT` unvalidated, defeating its own guard** — `.devstack/generate-config.sh:39-41` vs `:60` and `:83`

`check_safe_value` is applied to `DB_NAME`, `DB_USER`, `DB_PASSWORD` only, but `HTTP_PORT` is interpolated unescaped into both the sed replacement (`:60`) and the verification pattern built from the same value (`:83`). With `HTTP_PORT=80'` the script writes

    $CFG->wwwroot   = 'http://localhost:80'';

a PHP parse error, and the grep at `:83` — built from that same unescaped value — matches the broken line, so verification passes and the script prints `Wrote .../config.php` and exits 0. This is verbatim the failure the script's own comment at `:36-38` and `LOCAL-ENV.md:124-132` say the guard exists to prevent. It is then sticky: `config_is_ours` matches the `'http://localhost` prefix of the broken line, so every later run short-circuits on "config.php already exists, leaving it as is" and never regenerates. Only `dev:reset` recovers.

**2. `check:certificate` permanently disables `local/certengine/cli/seed_example.php`** — `.devstack/render-test-certificate.php:88-91` vs `local/certengine/cli/seed_example.php:50-51`

The render test creates cargo `ponente` when absent. `seed_example.php` hard-exits on exactly that record:

    if (cargo::get_record(['shortname' => 'ponente'])) {
        cli_error("El cargo 'ponente' ya existe. Nada que hacer.");
    }

Confirmed on the running stack after two task runs: `local_certengine_cargo (shortname=ponente): 1`. A developer who runs the new check task before the repo's own example seeder can never run the seeder on that site. The render test reuses the cargo but seeds no `cargo_label` rows, so `{{cargo}}` in the body resolves through a degraded path the seeder would have populated.

**3. `check:certificate` accumulates data without bound** — `.devstack/render-test-certificate.php:34-36`

Every run creates a new course (`certrendertest-` . time()), a customcert instance and a participant row, and deletes nothing. After two runs on this stack:

    certrendertest courses: 2
    customcert instances: 2
    participants: 2

`LOCAL-ENV.md:178` calls the course "throwaway"; nothing throws it away. A task meant to run on every change to the certificate pipeline grows the dev site each time.

**4. The cetext assertion is a hardcoded copy of `seed_example.php`'s body text and fails on a legitimate edit** — `.devstack/render-test-certificate.php:98`, `:100`, `:214-215`

`$bodyfragment = 'por haber'` is asserted on every run, including runs that reuse a pre-existing variant named `Ponente` (`:100`) whose body this script did not write. `cetext`'s own docblock states the body "vive en `local_certengine_variant.bodytext`, editable desde la biblioteca de variantes" — editing it there, the intended workflow, makes the task fail with

    check:certificate FAILED: rendered PDF does not contain the seeded cetext body text ('por haber'); cetext may be silently rendering nothing.

diagnosing a rendering bug that does not exist. The string also duplicates `seed_example.php:73-74` with no link between the two.

**5. `deploy.yml`'s new comment cites an example that is false** — `.github/workflows/deploy.yml:53-56`

> several of these names (config.php, mise.toml) also occur elsewhere in Moodle core

`git ls-files | grep mise.toml` returns nothing; the new root file is the only one. Only `config.php` has duplicates (six). `.cicat/DEPLOY.md:84-94` states this correctly, so the workflow comment and the doc it points at disagree, and the reader who checks the claim finds the rule's stated justification half wrong.

**6. `--exclude='/config.php.tmp.*'` can never match** — `.github/workflows/deploy.yml:65`

The job syncs from `actions/checkout@v4`. `config.php.tmp.$$` is a git-ignored artefact that only `generate-config.sh` creates, on a developer machine, and only survives a SIGKILL past its EXIT trap. It cannot exist in a CI checkout.

**7. The generated dev `config.php` carries production comments that are false for it** — `.devstack/generate-config.sh:56-66`

sed rewrites the values but not the prose around them, so the generated file reads:

    // Production currently uses 0777. 02770 (setgid, no world access) is tighter
    ...
    $CFG->directorypermissions = 02777;

and, above `$CFG->dataroot = '/var/www/moodledata';`, "the docroot is .../aulavirtual.cicat.edu.pe/intranet, so this path (a sibling of the docroot, not a child) is correctly unreachable over HTTP" — which describes neither path. The header still says "Copy this file to the Moodle root as config.php and fill in the real values."

**8. `LOCAL-ENV.md` contradicts `lib.sh` on runtime selection** — `.cicat/LOCAL-ENV.md:15-16` vs `.devstack/lib.sh:27`

The doc says "Tasks detect whichever is actually usable and use it; you do not choose." `lib.sh:27` is `if [ -z "${COMPOSE:-}" ]`, an environment override that is either real and undocumented or dead.

**9. `dev-install.sh` misdiagnoses any non-zero post-upgrade exit as a stale schema** — `.devstack/dev-install.sh:71-72`

The `elif` catches every non-zero code and asserts "still reports the schema stale ... install.xml was edited without bumping version.php". Exit 2 from that script means "Database is not yet installed", and the top-level `else` at `:88` already establishes that codes other than 0/1/2 are treated as unknown. The branch names a cause it has not established.

**10. `LOCAL-ENV.md:200-206` documents an error in an unavailable external document**

"The task brief that shaped this stack named `admin/cli/checkdatabase.php`..." is an unresolvable reference for any reader of the repository. It belongs in the PR description.

Unrelated churn: `.cicat/UPGRADE.md:45`, `.cicat/config.php.example:1` and `:28-29`, and `.github/workflows/deploy.yml:12` change only to replace em dashes, enlarging the diff of a branch whose subject is the local dev stack.

GATE: FAIL
