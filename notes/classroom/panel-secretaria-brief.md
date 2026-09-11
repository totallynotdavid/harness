# Fix the authorization gap on certificate deletion

This repository is the docroot of https://aulavirtual.cicat.edu.pe, a live
Moodle 5.0.4 site. Nothing here deploys on merge. Read `README.md`,
`.cicat/CUSTOMIZATIONS.md` and `.cicat/LOCAL-ENV.md` first, then bring the
stack up with `mise run dev` and confirm `mise run check` passes before you
change anything.

`local/panel_secretaria` is CICAT's own code, not vendored Moodle. You may
edit it.

## The defect

`local/panel_secretaria/eliminar.php` deletes a row from `customcert_issues`,
which revokes a certificate a student has been issued. It is guarded by:

    require_capability('local/panel_secretaria:view', $context);

Three things are wrong with that line, and the third is the one that matters.

1. `local/panel_secretaria:view` is declared in `db/access.php` with
   `'captype' => 'read'`. A read capability is guarding a destructive write.
2. Its archetypes grant it to `editingteacher` and `coursecreator`, not just
   `manager`. Every teacher on the site holds it.
3. `$context` is `context_system::instance()`, and the record is loaded by
   `required_param('issueid')` with no check tying that issue to any course
   the actor teaches. So a teacher in one course can delete a certificate
   issued in any other course on the site.

The capability declaration also carries no `riskbitmask`. A capability that
destroys student records should declare `RISK_DATALOSS` so it shows up in
Moodle's capability overview and role-definition warnings.

Confirm all of this yourself before you fix it. Do not take this brief's word
for the current state of the code.

## What to decide

Read how Moodle's own plugins guard a comparable destructive action, and how
upstream `mod_customcert` guards deleting an issue, then decide the shape.
State the decision and why in the commit body. Points to settle:

- Whether the fix is a new capability or a reuse of an upstream one.
- Whether the check belongs at system context or the certificate's own course
  context, given the secretariat is a site-wide role but teachers are not.
- Whether an existing production role would lose access it currently relies
  on, and what the site admin must do after deploy if so. Say this plainly
  in the commit body, because it is the part that bites on the live site.
- Whether the missing confirmation interstitial is worth adding while you are
  here. `require_sesskey()` is already present, so CSRF is covered and this
  is a usability question, not a security one. Decide and say which.

Check the rest of the plugin while you are in it. `ajax_estado.php`,
`crear_ponente.php` and `motor_ponente.php` were not audited, and the same
mistake may appear more than once. Report what you find even if you do not
change it.

## Deliverable

The authorization gap closed, with any capability change reflected in
`db/access.php` and a `version.php` bump so Moodle installs the new
capability on upgrade. A capability added without a version bump does not
exist on the running site, and that failure is silent.

## Verification

`mise run check` and `mise run check:certificate` both exit 0 from a cold
start.

Those prove you broke nothing. They do not prove you fixed anything, because
neither exercises this file. So also demonstrate the fix directly against the
local stack: create a certificate issue, create a user holding only the
teacher role, and show that the delete is refused for that user and allowed
for a manager. Use `mise run dev:php` to drive Moodle CLI. Describe exactly
what you ran and what it printed.
