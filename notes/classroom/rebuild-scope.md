# What the replacement has to do

Read-only investigation of `~/git/cicat/classroom` to establish what CICAT's Moodle
actually does, ahead of any decision about rebuilding it on Nuxt. Nothing in the
worktree was changed.

## Verdict

This is not a general LMS in active use for teaching. It is a certification and
event-attendance platform built on Moodle's course machinery. The only two activity
modules added beyond stock Moodle are `mod/customcert` and `mod/zoom`. The three
bespoke plugins, roughly 4,300 lines of original PHP, exist for one purpose:
generating, pre-printing, and administering certificates.

That materially shrinks the rebuild. It also moves the risk: the hard part is not
replacing Moodle, it is reproducing certificate rendering and the pre-issue workflow
exactly, because verification codes are permanent public artifacts.

## Day-to-day flow

1. A course runs using stock Moodle activities, with `mod_zoom` for live sessions.
2. A quiz gates a `customcert` certificate activity. `local/certpreissue/classes/manager.php:655`
   (`detect_quiz_cmid()`) parses the certificate's own availability-restriction JSON to
   find which quiz and grade gate it.
3. Secretariat staff pre-print every certificate before the exam happens. This is the
   whole reason `local_certpreissue` exists: generate a signed PDF for every enrolled
   student in advance, with a fixed verification code, so they can be physically printed
   and hand-signed ahead of time and released the instant the student passes.
4. External, non-enrolled people also receive certificates: speakers, moderators,
   organisers, coordinators. `local_certengine\recipient_service` creates them with
   `nologin` auth and an undeliverable `@certengine.invalid` address.
5. Students request a physical copy through a Moodle Feedback activity named
   `%Certificado Físico%`, parsed by the secretariat panel into pickup versus
   mail-to-province with address and phone.
6. The secretariat panel browses every issued certificate site-wide, downloads it signed
   or unsigned, revokes it, and jumps into core's user-edit form.

### Roles with direct evidence

| Role | Evidence |
|---|---|
| Student | `mod/customcert/db/access.php` grants `receiveown`. Pre-issued certificates are deliberately invisible until release. |
| Teacher / editing teacher | `local/certpreissue/db/access.php` clones `:viewreport` and `:manage` from customcert, granted to `teacher` and `editingteacher`. |
| Secretariat | `local/panel_secretaria/db/access.php` grants `:view` to the `manager`, `coursecreator`, `editingteacher` archetypes at system context. The real role name is a live DB fact, not in the code. |
| Manager / admin | Owns `local_certengine:manage`: cargo catalogue, asset library, variant rules. |
| External recipient ("ponente") | `local_certengine\recipient_service`. Someone who will never log in but must receive a certificate. |

## Certificate domain model

Two cooperating plugins. `local_certengine` decides what a certificate contains;
`local_certpreissue` decides when it is handed out. `mod_customcert` hosts the PDF layout.

### local_certengine

Tables from `local/certengine/db/install.xml` (version 20260715):

- `local_certengine_cargo` - catalogue of positions printed on a certificate (listener,
  speaker, moderator). `shortname` unique, `sortorder`, `active` for soft-delete so
  historical issuances stay valid.
- `local_certengine_cargolbl` - gendered and localised label text. Separate table because
  the label depends on cargo + gender + language, not cargo alone. `gender` (`m`/`f`/`n`),
  `lang`, `label`, `article` for `{{art}}` tokens. Unique on `(cargoid, gender, lang)`.
- `local_certengine_variant` - a layout plus base text. `templateid` weak FK to
  `customcert_templates`, `bodytext` holding placeholders like
  `{{titulo}} {{nombre}}, rol de {{cargo}}, {{fechas}}`.
- `local_certengine_rule` - maps a user context to a variant. `priority` ascending,
  lower wins. `matchtype` one of `cargo`, `role`, `group`, `cohort`.
- `local_certengine_particip` - the per-user, per-course row. Deliberately does not
  duplicate name, course, or dates; those are read live from Moodle at render time.
  Holds `cargoid` plus `variantoverride`, `titleoverride`, `nameoverride`, `dateoverride`.
  Unique on `(courseid, userid)`.
- `local_certengine_asset` - versioned metadata for backgrounds, signatures, stamps.
  Binary lives in Moodle's File API. `name` is a stable logical name repeating across
  versions; `active` marks the current one. Never deleted, so already-issued certificates
  referencing an old version keep rendering correctly. Unique on `(type, name, version)`.
- `local_certengine_slot` - binds a named hole in a variant's layout to a logical asset
  per emission mode. `slotname` (`background`, `signature1`, `signature2`, `stamp`),
  `mode` (`digital`/`print`/`any`). Resolution takes the latest active version: last
  uploaded wins, no manual relinking.
- `local_certengine_issue` - an immutable snapshot. `payload` is deliberately denormalised
  JSON so a signed certificate never silently changes if the signature image or wording
  is edited later.

Resolution, in `local/certengine/classes/resolver.php`, given `(userid, courseid, mode)`:
load gender and academic title from custom profile fields (configurable, default
`genero`/`titulo`); resolve cargo, then its gendered label falling back gender to neutral
to any; resolve title and name from override or profile; resolve variant from
`variantoverride` else the first active rule by priority; resolve assets for that variant
and mode; resolve dates from override else course start and end; assemble a token map and
freeze it into a `resolved_certificate` value object.

`local/certengine/classes/token_substitutor.php` is a small pure engine: `{{token}}` with
`|upper`, `|lower`, `|title`, `|cap` modifiers, multibyte-safe via `core_text`, missing
tokens render empty rather than leaking the placeholder.

### local_certpreissue

One table, the shadow issue. `code` is the definitive verification code, generated up
front and deduped against both `customcert_issues` and the shadow table. `printmode`,
`timecreated`, `timegenerated`, `timereleased`, `issueid`, `timedirty` with `dirtyreason`
(`user`/`group`/`engine`/`manual`), and `datahash`, a sha1 of every input that fed the
render. Unique on `(customcertid, userid)`.

The workflow:

1. **Pre-issue.** For every enrolled student, generate the definitive code and render the
   PDF. Rendering inserts a transient row into `customcert_issues` inside a transaction so
   customcert's own code and QR elements can read it, then deletes it before commit
   (`manager::render_pdf`, ~lines 249-297). `customcert_issues` stays clean, so the
   student's "My certificates" page, the email task, and the public verification page see
   nothing. The PDF is stored in the plugin's own file area.
2. **Print mode.** Driven by `$SESSION->customcert_printmode`, consumed by an interceptor
   in patched `mod/customcert/classes/template.php` that skips a background element by
   matching its configured name against the literal strings `fondo digital` or
   `fondo imprenta`, case-insensitively.
3. **Release.** Automatic, not manual. Five event observers (`local/certpreissue/db/events.php`)
   fire on completion update, quiz attempt submission, and grade change, each calling
   `manager::check_and_release()`, which re-checks the same availability gate
   `mod_customcert/view.php` enforces before inserting the real row using the
   pre-printed code. A scheduled task sweeps every 5 minutes as backstop.
   `mod_customcert\event\issue_created` is fired manually so logs and the email task stay
   consistent with a normal issuance.
4. **Race reconciliation.** If stock customcert issues first with its own code,
   `manager::link_real_issue()` either overwrites that code with the pre-printed one
   (default, `reconcilecode` setting) so the physical QR still verifies, or adopts the
   stock code and marks the printed PDF stale.
5. **Staleness.** `local/certpreissue/classes/fingerprint.php` hashes every mutable input:
   full name, institution, idnumber, picture, code, printmode, template `timemodified`,
   group id and name pairs (because `cargogrupo` matches groups by name), and both
   digital and print token resolutions. Observers flag shadows dirty without re-rendering
   inline; `refresh_task` re-renders under a hard batch and time budget, staggered 2
   minutes off `release_task` so they never queue together. A bulk profile edit cannot
   saturate the web server.

## Secretariat panel

`local/panel_secretaria` is a single 334-line `index.php` with three tabs, plus one table
`local_panelsec_envios` tracking physical shipment status.

- **Certificados Digitales** - every issued certificate site-wide, joined across
  `customcert_issues`, `customcert`, `course_modules`, `course`, `role_assignments`.
  Per row: edit user, download unsigned, download signed, delete the issue.
- **Solicitudes Físicas** - parses `mod_feedback` responses into delivery requests,
  toggled pendiente/enviado.
- **Buscador de Cursos** - a flat quick-jump course index.

The core patch to `user/editadvanced.php` exists because the panel's edit link is
`moodle_url('/user/editadvanced.php', ['id' => ..., 'returnto' => 'panel'])`. It reuses
Moodle's own full user-edit form rather than reimplementing one, and needs the two-line
patch purely so Save returns to the panel. That is a genuine integration point: core
offers no other way to round-trip back into a plugin page.

## Day one, later, dropped

**Day one.** Certificate content model (cargo catalogue with gendered labels, variant
library, rule-based resolution, versioned assets with history retained). Pre-issue
workflow (bulk pre-generate, print versus signed, automatic release on completion, code
reconciliation, staleness with throttled re-render). External recipient creation without
login. Secretariat cross-course console with both renderings, revoke, and edit person.
Physical fulfilment tracking as a first-class entity. PDF rendering with the custom font
families and the grade-in-words rule. Quiz-gated eligibility. Live-session integration
equivalent to `mod_zoom`.

**Later.** CSV/Excel export of the pre-issue report. Auto-refreshing exam-window monitor.
CLI tooling mirroring `cli/create_external.php`, `cli/attach_asset.php`,
`cli/assign_participant.php`. Certificate design preview. A finer authorisation model.

**Dropped.** Badges, competencies, LTI, portfolios, blogs, wikis, glossary, lesson,
workshop, H5P - all present only because Moodle ships them; nothing in the bespoke
plugins references them. MNet, AI placements, report builder. The
`mod_feedback`-as-request-form hack: drop the mechanism, keep the requirement.
`local/panel_secretaria/motor_ponente.php`, a second external-recipient implementation
using manual-login accounts with DNI as password and a hard-coded `teacher` role, marked
"Función En Desarrollo" and unlinked from its own UI. `filter_generico`,
`availability_role`, `theme_adaptable` have no CICAT logic to port.

## Hard parts

- **Fonts.** `dinpro_b`, `dinpro_medium`, `scriptmtb`, `scriptmtbmod` are TCPDF font
  packages under `lib/tcpdf/fonts/`. Whatever PDF library replaces TCPDF needs these exact
  families licensed and converted.
- **Two undocumented customcert patches.** Both live in `mod/customcert` and neither is in
  `.cicat/CUSTOMIZATIONS.md`, which claims the four added elements are the only non-upstream
  surface:
  - the background interceptor described above, a second parallel mechanism to
    `certengine`'s slot-based `ceasset` resolution, both live simultaneously today;
  - a grade element patched to render Peruvian-style "19 (diecinueve)" for grades 0-20,
    and to render **blank** rather than "0 (cero)" when there is no grade yet. That blank
    is load-bearing: it is exactly what lets staff print and pre-sign before results exist.
- **`autofitname`** shrinks font size in a loop against measured PDF string width until it
  fits, and falls back to a `user.institution` prefix when the newer `certengine` title is
  unset. That fallback must be preserved for already-issued certificates to render
  identically.
- **The transient-row trick.** Inserting a fake `customcert_issues` row inside a
  transaction purely so PDF elements can read it is clever and fragile. A rebuild should
  take all render inputs explicitly and need no such trick, but the behaviour it produces
  (identical code before and after real issuance, verification page never shows an
  unearned certificate) is non-negotiable.
- **Migration.** Every issued certificate is an immutable snapshot by design. Verification
  codes and QRs are permanent public artifacts, so old codes must keep resolving after the
  platform changes. That is an external-facing constraint, not a data-migration nicety.
- **Zoom.** Either a from-scratch Zoom API integration or a different vendor. A decision to
  escalate, not infer.
- **The shipment FK.** `local_panelsec_envios.valueid` points into `mod_feedback` internals,
  and the code is inconsistent about whether it means `feedback_value.id` or
  `feedback_completed.id` (`index.php`'s SQL versus `ajax_estado.php`'s param name). No
  clean migration path; rebuild as a first-class table.

## Open, needs the live site

- The exact name of the secretariat role. `db/access.php` names archetypes only.
- `theme_adaptable` configuration: logo, colours, menus, custom CSS, blocks. All in
  `mdl_config_plugins`, not the repo.
- Whether `filter_generico` and `availability_role` are enabled, and where.
- Actual course volume, and whether `assign`/`quiz`/`forum` carry real teaching or exist
  only to gate certificates. Only their gating role is proven by code.
- The real Feedback activities behind physical requests. The parser guesses "1"/"2" answer
  meanings and sniffs phone versus address by keyword, which is itself evidence the data is
  informally structured.
- Whether the two patches above are the only silent deviations from stock `mod_customcert`
  5.0.3. They were found by chasing a remark in `local_certpreissue/README.md`, not from
  the customizations doc. Someone should diff the full `mod/customcert` tree against a
  clean 5.0.3 tarball - not against `vendor`, which does not contain the plugin at all.
- Which plugin features are actually exercised: asset library, rule engine, CLI tools, ZIP
  bulk download, autorefresh reporting. Only live logs can say.

## Capability-modelling gap worth fixing regardless

Deleting a certificate in the secretariat panel is guarded by
`local/panel_secretaria:view` - the read capability, not a manage or write one. Anyone who
can open the panel can hard-delete an issued certificate.
