# Upgrade mod_customcert from 5.0.3 to 5.0.7

This repository is the docroot of https://aulavirtual.cicat.edu.pe, a live
Moodle 5.0.4 site. Nothing here deploys. Read `README.md`,
`.cicat/CUSTOMIZATIONS.md` and `.cicat/LOCAL-ENV.md` first, then bring the
stack up with `mise run dev` and confirm `mise run check:certificate` passes
before you change anything. A baseline you did not observe is not a baseline.

`notes/classroom/plugin-audit.md` in the captain repository is the audit that
produced this task. Read its `mod_customcert` section. Do not re-derive it.

## Why

The installed 5.0.3 is not vulnerable to CVE-2026-30884; that fix is present
and was verified in the source. Four releases since then close a second
instance of the same authorization-bypass class in `load_template.php`, add
missing capability checks on `get_element_html()`, fix a login-ordering
probe in `my_certificates.php`, fix two CSRF holes, and stop storing digital
signature passwords in plaintext. `$plugin->requires` is unchanged across the
whole range, so nothing here is a breaking change for this site.

## The hazard that makes this a task and not a copy

Four certificate elements that are not upstream live inside the plugin:

    mod/customcert/element/autofitname
    mod/customcert/element/cargogrupo
    mod/customcert/element/ceasset
    mod/customcert/element/cetext

Moodle requires a subplugin to live inside its parent's declared path, so
these cannot be moved out. That is a structural constraint, already checked;
do not spend time proposing an extraction.

`ceasset` and `cetext` read from the `local_certengine` plugin. Whatever you
do must leave that working.

## Deliverable

`mod/customcert` at upstream 5.0.7 with the four CICAT elements intact.

Establish the CICAT layer before you overwrite anything: diff the installed
tree against upstream's 5.0.3 tag file by file and write down every
difference, not just the four element directories. A CICAT edit inside an
upstream file is the failure mode this task exists to catch, and if one
exists it must be re-applied deliberately or dropped deliberately. Record
what you found in the commit body.

Upstream is `github.com/mdjnelson/moodle-mod_customcert`, branch
`MOODLE_500_STABLE`. Take the newest tag on that branch rather than 5.0.7 if
one has appeared since this brief was written, and say which you took.

Stay on the 5.0 line. Core moves to a newer Moodle in separate work, and
this task exists to establish and rehearse the re-application procedure
before that happens, not to anticipate it.

## Verification

`mise run check` and `mise run check:certificate` both exit 0 from a cold
start, with the containers and volumes destroyed first. `check:certificate`
renders a certificate carrying all four CICAT elements and asserts each one
produced its distinguishing output: `cetext`'s body text and `ceasset`'s
embedded image via `pdftotext`, `cargogrupo`'s in-group text, and
`autofitname`'s shrunk bounding box. Each assertion has been shown to catch
the corresponding element rendering nothing. Use it, and read
`.cicat/LOCAL-ENV.md` for what it does and does not cover before you trust it.

**That guard is not sufficient on its own, and the earlier version of this
brief was wrong to imply it was.** `local_certengine` does not go through
`mod_customcert`'s API. Twelve of its files query customcert's database
tables directly: `customcert_issues`, `customcert_templates`,
`customcert_pages`, `customcert_options` and `customcert_printmode`. An
upstream release that renames a column or changes a table breaks certengine
while `check:certificate` still passes, because that check renders a
certificate through customcert itself and never exercises certengine's
queries.

So before you upgrade, read customcert's `db/upgrade.php` and `db/install.xml`
across the whole 5.0.3 to 5.0.7 range and list every schema change to those
five tables. Then find every certengine query that touches them and say, for
each schema change, whether a query depends on what changed. If any does,
that is the real work of this task and it must be fixed and demonstrated, not
just noted. If none does, say so explicitly and show how you established it.

Exercise certengine itself after the upgrade, not only the renderer. Issue a
certificate through whatever path certengine owns and confirm it still
appears, still verifies, and still carries its pre-issue code.

Also run the plugin's upgrade path, not just a fresh install: install at
5.0.3 first, then upgrade in place, so the database upgrade steps between the
two versions actually execute.

Report the version numbers you started and finished at, and say plainly
whether any CICAT change inside an upstream file was lost.
