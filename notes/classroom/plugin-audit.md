# Plugin audit: third-party layer, upgrade cost

Scope: the five third-party plugins listed in `.cicat/CUSTOMIZATIONS.md` §3, plus
the two hazards it already flags (customcert elements, TCPDF fonts). Read-only;
nothing in the worktree was changed. Site runs Moodle core 5.0.4 (branch `500`,
core version `2025041404`).

A methodology note up front: `moodle.org/plugins/<name>` now 303-redirects to
`marketplace.moodle.com`, which returns HTTP 403 to automated fetches. Every
finding below is instead sourced directly from each plugin's own upstream Git
repository — read at the branch that tracks Moodle 5.0 where the maintainer
keeps one (customcert, Adaptable, availability_role all do; Zoom and Generico
develop on a single trunk) — cross-checked against the plugin's own
`version.php` and `CHANGES.md`/changelog file. Where a Moodle forum
announcement is the only corroborating source, that's noted.

**A caution on version numbers**: Moodle plugin `$plugin->version` values are
`YYYYMMDDXX`, but the `YYYYMMDD` part is the Moodle *branch's* branching date,
frozen for the life of that branch — not the real release date. `mod_customcert`
5.0.3's version number encodes April 2025, but the commit that produced it
actually landed **March 15, 2026**. Real dates below come from commit history
and changelogs, not from decoding version numbers.

## Summary

| Plugin | Installed | Latest (for our Moodle 5.0 branch) | Risk |
|---|---|---|---|
| `theme_adaptable` | 500.2.8 (2025040814) | 500.2.9 (2025040815), 2026‑08‑29 | Low |
| `mod_customcert` | 5.0.3 (2025041405) | 5.0.7 (2025041410), 2026‑08‑23 | **High** |
| `mod_zoom` | v5.5.0 (2026041600) | v5.5.1 (2026082400), ~2026‑08‑27 | Low |
| `filter_generico` | 1.4.25 (2025100500) | 1.4.25 (2025100500) — current | Low |
| `availability_role` | v5.0‑r5 (2025041407) | v5.0‑r5 (2025041407) — current | Low |

Only `mod_customcert` carries a real gap with security content, and it also
carries the extraction hazard below — it is the one item the captain needs
named as a cost, not just a line on a list.

---

## 1. `theme_adaptable` (`theme/adaptable`)

**Installed**: `theme/adaptable/version.php` — `version = 2025040814`,
`release = '500.2.8'`, `requires = 2025041400.00` (Moodle 5.0.0+).
`.cicat/CUSTOMIZATIONS.md` doesn't record a version for this plugin, so there's
nothing to disagree with.

**Upstream**: maintainer `gjbarnard/moodle-theme_adaptable` on GitHub keeps a
separate stable branch per Moodle version. `MOODLE_500` is one release ahead:
`500.2.9` (version `2025040815`), committed 2026‑08‑29 — eleven days before
this audit. The `main` branch (tracking Moodle 5.2, the newest branch Adaptable
supports) was bumped to `502.1.4` the same day, confirming the author still
releases across all supported branches together, i.e. this plugin is very
actively maintained.

**The gap** (500.2.8 → 500.2.9), per `Changes.md` on `MOODLE_500`: fix for a
guest-detection call (`isguestuser` vs `isguestuser()`), a display fix in the
properties report, a Font Awesome bump to 7.3.0, a header-menu icon display
fix, a missing-array-index fix during upgrade, and a CSS fix for the icon
class Moodle's quiz page-break editor depends on. No security language, no
declared breaking change.

**Risk: Low.** One minor point release behind, on a plugin releasing every few
weeks. Source: `github.com/gjbarnard/moodle-theme_adaptable`, branch
`MOODLE_500`, `Changes.md` and commit history.

---

## 2. `mod_customcert` (`mod/customcert`)

**Installed**: `mod/customcert/version.php` — `version = 2025041405`,
`release = "5.0.3"`, `requires = 2025041400` (Moodle 5.0). This matches
`.cicat/CUSTOMIZATIONS.md`'s own note ("5.0.3 — patched, see below"); no
disagreement.

**The critical CVE is already patched here — verify before assuming otherwise.**
`mdjnelson/moodle-mod_customcert` (upstream) disclosed **CVE‑2026‑30884**
(CWE‑639, Authorization Bypass Through User‑Controlled Key, CVSS 9.6/Critical,
GHSA‑8pjr‑j7r4‑ccjx): a user holding `mod/customcert:manage` in any one course
could read and silently overwrite certificate elements belonging to any other
course, via an unvalidated `elementid` in the `editelement` fragment callback
and the `mod_customcert_save_element` / `mod_customcert_get_element_html` web
services. The advisory states this is fixed **in 5.0.3** for the 5.0.x branch.
I confirmed by fetching `version.php` from the exact upstream commit
(`e0388cecce8810d1a6121da4ec4a475b49a760ee`, 2026‑03‑15, "Bumped version") that
produced release 5.0.3: it is byte-identical to the installed
`version = 2025041405`, `release = "5.0.3"`. I then read the local worktree's
`mod/customcert/lib.php:317-334` and `mod/customcert/classes/external.php:69-98`
directly and confirmed the ownership-validation code from the fix — the
context/template check against `elementid` — is present. **This install is not
vulnerable to CVE‑2026‑30884.**

**But four releases of further security hardening exist that this install
does not have.** The `MOODLE_500_STABLE` branch has moved on to `5.0.7`
(version `2025041410`, 2026‑08‑23), with `5.0.8` pending. Per that branch's
`CHANGES.md`:

- **5.0.4** (2026‑06‑10) — further hardened element/page ownership validation
  across additional handlers to prevent cross-template access.
- **5.0.5** (2026‑08‑02) — fixed a **second, related authorization bypass**
  in `load_template.php`, explicitly flagged by the maintainer as
  "CVE‑2026‑30884 related": the original fix did not close every instance of
  the same bug class.
- **5.0.6** (2026‑08‑10) — added missing capability checks on
  `get_element_html()`, and fixed a probing issue in `my_certificates.php`
  where the login check ran after certificate-issuance logic instead of
  before; the report-download flow now verifies the requesting user actually
  received the certificate before serving the PDF.
- **5.0.7** (2026‑08‑23) — fixed two CSRF vulnerabilities (the `view.php`
  self-download flow and the `ajax.php` element-position endpoint, both now
  require a valid session key), and fixed **plaintext storage of digital
  signature passwords** — passwords are now encrypted at rest and no longer
  echoed back into edit forms in cleartext HTML.

None of this is present in the installed 5.0.3. The `requires` field is
unchanged through 5.0.7 (still Moodle 5.0), so nothing here is a breaking
change for this site specifically — it is a straight, uncontested security
gap. Sources: `github.com/mdjnelson/moodle-mod_customcert`, branch
`MOODLE_500_STABLE`, `CHANGES.md` and commit `a1494a80fb953f187f7888a7394cbf9d13c28468`
("Security fix: validate element ownership before access (CVE‑2026‑30884)");
GHSA‑8pjr‑j7r4‑ccjx; NVD CVE‑2026‑30884.

**Maintained**: yes, very actively — commits into September 2026, releases
roughly every 2–6 weeks through 2026.

**Risk: High.** Not because of an unpatched critical CVE (there isn't one),
but because four subsequent releases close a second instance of the same bug
class, two CSRF holes, and a plaintext-credential-storage issue — combined
with the extraction hazard below, which is what actually blocks picking up
those fixes today.

---

## 3. `mod_zoom` (`mod/zoom`)

**Installed**: `mod/zoom/version.php` — `version = 2026041600`,
`release = 'v5.5.0'`, `requires = 2019052000` (Moodle 3.7+). No version
recorded in `.cicat/CUSTOMIZATIONS.md`, no disagreement.

**Upstream**: `jrchamp/moodle-mod_zoom`, single trunk (`main`), currently
`v5.5.1` (version `2026082400`), last commit 2026‑08‑27. Per `CHANGES.md`,
the gap consists of: removing a legacy `FEATURE_GROUPMEMBERSONLY` flag,
making calendar events respect group restrictions, "MDL Shield" hardening
(an internal safeguard feature, not a disclosed CVE), settings cleanup, and
adding a `LICENSE` file for the marketplace listing. No CVE, no breaking
change declared.

**A maintenance-status flag worth naming**: a commit on 2026‑08‑26 ("ci: drop
4.4, 5.0 testing (keep LTS); add 5.2") removed Moodle 5.0 — this site's exact
branch — from the project's CI test matrix, in favor of Moodle's LTS releases
and 5.2. `$plugin->requires` is unchanged (still 3.7+), so nothing stops this
plugin from installing or running here, but going forward new Zoom releases
are no longer verified against Moodle 5.0 before shipping. This is not a
today problem; it is the kind of drift that becomes one.

**Risk: Low.** One minor release behind with no security content in the gap,
but flag the dropped 5.0 CI coverage for the modernization-pass timeline.
Source: `github.com/jrchamp/moodle-mod_zoom`, `CHANGES.md` and commit history.

---

## 4. `filter_generico` (`filter/generico`)

**Installed**: `filter/generico/version.php` — `version = 2025100500`,
`release = 'Version 1.4.25 (Build 2025100500)'`, `requires = 2022112800`
(Moodle 4.1+). No version recorded in `.cicat/CUSTOMIZATIONS.md`.

**Upstream**: `justinhunt/moodle-filter_generico`, single trunk. `master`'s
`version.php` is presently identical to the installed one — `2025100500` /
`1.4.25`. **This install is current; there is no gap.** Two unreleased
commits sit on `master` from February 2026 (a dataset-field bug fix), but the
maintainer has not cut a new tagged version since, so there is nothing newer
to be behind.

Worth noting for context, since it's already covered: the two releases
immediately before this one were themselves security hardening —
`1.4.22` (2025‑06‑19, "prevent variable injection and meddling") and
`1.4.25` (2025‑10‑05, "more cleaning up of filter string inputs") — both
already included in the installed build.

**Risk: Low.** Fully current. Source: `github.com/justinhunt/moodle-filter_generico`,
`CHANGES.txt` and commit history.

---

## 5. `availability_role` (`availability/condition/role`)

**Installed**: `availability/condition/role/version.php` —
`version = 2025041407`, `release = 'v5.0-r5'`, `requires = 2025041400`
(Moodle 5.0). No version recorded in `.cicat/CUSTOMIZATIONS.md`.

**Upstream**: `moodle-an-hochschulen/moodle-availability_role` (a German
Moodle-hosting association), which — like customcert and Adaptable — keeps a
stable branch per Moodle version (`MOODLE_500_STABLE`, `MOODLE_501_STABLE`,
`MOODLE_502_STABLE` all exist). `MOODLE_500_STABLE`'s `version.php` is
identical to the installed one: `2025041407` / `v5.0‑r5`. **This install is
current.** Its last change (2026‑06‑23, a bugfix for a
`dml_missing_record_exception` when editing/evaluating restrictions on the
front page, which has no course category) is already included, since it *is*
the installed release. `master` has moved on to `v5.2‑r1`, requiring Moodle
5.2 — expected, since it tracks the newest branch only, and irrelevant to
this Moodle 5.0.4 install.

**Risk: Low.** Fully current, and the maintainer's per-branch release
discipline makes this one of the easiest plugins here to keep current.
Source: `github.com/moodle-an-hochschulen/moodle-availability_role`, branch
`MOODLE_500_STABLE`, `CHANGES.md` and commit history.

---

## Hazard: four CICAT certificate elements live inside `mod_customcert`

`mod/customcert/db/subplugins.json` declares:

```json
{
    "subplugintypes": { "customcertelement": "element" },
    "plugintypes": { "customcertelement": "mod/customcert/element" }
}
```

This is Moodle's standard subplugin mechanism, and `mod_customcert` does use
it as the officially supported way to add a certificate element type. All
four CICAT elements are properly formed subplugins, not ad-hoc code dropped
into the directory: each declares its own `$plugin->component`
(`customcertelement_autofitname`, `customcertelement_cargogrupo`,
`customcertelement_ceasset`, `customcertelement_cetext`) and its own
`version.php`. They are small: `autofitname` is 4 files / 143 lines,
`cargogrupo` 4 files / 109 lines, `ceasset` 3 files / 217 lines, `cetext`
3 files / 108 lines — 14 files and 577 lines total.

**The hazard is structural, not a shortcut CICAT skipped.** Moodle's
subplugin mechanism requires a subplugin to physically live inside the path
its parent plugin declares in `subplugins.json` — here, fixed at
`mod/customcert/element`. There is no supported Moodle mechanism for a
`customcertelement` subplugin to be registered from a location outside
`mod_customcert`'s own directory tree, the way an independent `local_` or
`mod_` plugin can install anywhere Moodle scans that plugin type. So even
though these four are well-formed subplugins, no amount of restructuring
turns them into something that survives a directory-level `mod_customcert`
upgrade unattended — every upgrade will keep requiring the four directories
to be copied back in, by the nature of how Moodle subplugins work, not
because of how CICAT wrote them.

Three of the four elements' actual code — `autofitname`, `ceasset`, `cetext`
(all but `cargogrupo`) — call into `local/certengine`'s `course_resolver`
class (`mod/customcert/element/{autofitname,ceasset,cetext}/classes/element.php`).
The dependency runs from the third-party plugin's subplugins into the
CICAT-authored plugin, not the reverse: `local/certengine` itself only
mentions these element names once, in a code comment
(`local/certengine/classes/course_resolver.php:10`), and doesn't call into
them. So `local/certengine` isn't tightly coupled to *where* these four
elements live — it just needs to keep existing and keep exposing
`course_resolver` for three of the four to keep working, wherever they end up.

---

## Hazard: four TCPDF font families live under `lib/tcpdf/fonts`

The four families (`dinpro_b`, `dinpro_medium`, `scriptmtb`, `scriptmtbmod`)
are present as expected — 12 files (`.php`/`.z`/`.ctg.z` per family) under
`lib/tcpdf/fonts/`.

**Moodle already has a supported, documented mechanism for fonts outside
core, and it is not currently used here.** `lib/pdflib.php:18-69` — Moodle's
own PDF wrapper around TCPDF — defines a `PDF_CUSTOM_FONT_PATH` constant,
defaulting to `$CFG->dataroot . '/fonts/'`, i.e. `moodledata/fonts/`, a
location entirely outside the vendored `lib/tcpdf` tree (and, per
`.cicat/CUSTOMIZATIONS.md` §6, already outside this repository — `moodledata`
is deliberately excluded from git). The file's own doc comment is explicit:
*"You should always copy all fonts from lib/tcpdf/fonts/ to your
PDF_CUSTOM_FONT_PATH and then add extra fonts."* `lib/pdflib.php:87-117`
implements this: if `PDF_CUSTOM_FONT_PATH` is a directory, Moodle checks it
contains a working set of TCPDF's standard fonts (`courier`, `helvetica`,
`times`, `symbol`, `zapfdingbats`, `freeserif`, `freesans`) before pointing
TCPDF at it via `K_PATH_FONTS` — if any are missing, Moodle silently falls
back to `lib/tcpdf/fonts/` instead. That means the custom path is a
**wholesale replacement** of the font directory, not a place to drop only
the four extra families — the standard set has to be copied there too, or
the override does nothing.

Separately, TCPDF's own font-loading code (`lib/tcpdf/tcpdf.php`'s
`AddFont()`, backed by `TCPDF_FONTS::_getfontpath()`) has no restriction
against loading from wherever `K_PATH_FONTS` points — the mechanism above is
the whole of what's needed, nothing further in TCPDF forbids it.

What a Moodle/TCPDF upgrade does to `lib/tcpdf/fonts/` as things are
currently configured: `.cicat/CUSTOMIZATIONS.md` §4's assessment holds up —
TCPDF is vendored as a single wholesale copy inside `lib/tcpdf`, so a
`vendor` branch merge will see the four extra families as untouched
additions and keep them by default. No name collision risk was found: TCPDF
upstream ships no font files named `dinpro_*` or `scriptmtb*`. The
verification step `.cicat/CUSTOMIZATIONS.md` already recommends — confirm
certificates still render after any upgrade that touches TCPDF — remains the
right check either way.
