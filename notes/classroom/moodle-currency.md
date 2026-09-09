# How far behind is this Moodle?

**This tree is at Moodle 5.0.4, built 2025-12-08 — the exact official 5.0.4 release.
The newest release on the same branch is 5.0.9, released 8–10 August 2026, eight
months and five point releases later. Recommendation: move with real but not
panicked urgency — none of the disclosed fixes in the gap are known to be remotely
exploitable pre-authentication on this configuration, but Moodle 5.0's security
support ends 5 October 2026, about four weeks from today, so the window to
upgrade in a calm, tested way is closing.**

Sources are moodle.org, docs.moodle.org (which now redirects its release-schedule
page to moodledev.io), and moodledev.io/general/releases (Moodle's own developer
site, linked as authoritative by docs.moodle.org itself). Where I could not
confirm something from an official source, it's marked as such below rather than
filled in.

## 1. Newest release on the 5.0 branch

**Moodle 5.0.9**, the newest 5.0.x release as of today (2026-09-08).
[moodledev.io](https://moodledev.io/general/releases/5.0/5.0.9) gives its release
date as **10 August 2026** (page "last updated" 7 August 2026); the parallel
[download.moodle.org security-releases page](https://download.moodle.org/releases/security/)
gives **8 August 2026**. The two-day discrepancy is unresolved — both are
first-party Moodle properties and I found no way to adjudicate it, so treat the
date as "early-to-mid August 2026." Moodledev.io itself calls 5.0.9 "one of the
last 5.0 formal releases," noting "the 5.0 branch is very old now and is not
being improved except for major security and dataloss fixes."

This tree's `version.php` reports `5.0.4 (Build: 20251208)`. I confirmed
2025-12-08 is 5.0.4's actual release date (not a later unnumbered weekly build
of 5.0.4) via [moodledev.io/general/releases/5.0/5.0.4](https://moodledev.io/general/releases/5.0/5.0.4).
So the tree is exactly at the 5.0.4 release, not ahead of or behind it by a
build cycle.

## 2. Every 5.0.x release between build 20251208 and 5.0.9

Table built from [moodledev.io's per-release pages](https://moodledev.io/general/releases/5.0)
and [moodle.org/security](https://moodle.org/security/) (advisories, in Moodle's
own Minor/Serious/Critical severity scale — not CVSS). MSA-25-0051 through
-0061, which the 5.0.4 release notes list as already fixed in this tree's exact
build, are **not** included below; they're already applied.

| Release | Date | Security fixes (MSA, severity, one-line description) |
|---|---|---|
| **5.0.5** | 9 Feb 2026 | MSA-26-0001 **Serious** — RCE via file restore (CVE-2026-26045). MSA-26-0002 **Serious** — RCE in TeX filter admin setting, requires admin access + ImageMagick (CVE-2026-26046). MSA-26-0003 **Serious** — DoS in TeX formula editor. |
| **5.0.6** | 11 Feb 2026 | None. Emergency non-security fix for a 5.0.5 regression (MDL-87892, see §5). |
| **5.0.7** | 20 Apr 2026 | MSA-26-0005 **Serious** — SQL injection in `auth_db` (external database authentication). MSA-26-0006 **Serious** — RCE via the Google Drive repository plugin. MSA-26-0007 **Minor** — messaging breaks/DoS when a conversation includes a deleted user. MSA-26-0009 **Minor** — CSRF in grade-penalty-rules reset. MSA-26-0010 **Minor** — upstream AWS SDK for PHP fix. MSA-26-0011 **Minor** — missing CSRF token/capability check on an MNet admin setting. |
| **5.0.8** | 8 Jun 2026 | 18 advisories, MSA-26-0012 through -0029. **Serious**: 0012 arbitrary file read via mod_data (Database activity) import; 0013 email-based MFA bypass (still requires valid credentials); 0014 arbitrary file read via backup restore; 0015 RCE via admin presets import (admin access required); 0017 IDOR allowing arbitrary comment deletion; 0021 CSRF/XSS in grade-item ID-number editing; 0025 CSRF in quiz attempt regrading; 0026 missing capability check in assignment marker allocation; 0028 DoS via unbounded user-profile description length. **Minor**: 0016 (grade web-service group check), 0018 (CSRF, user homepage preference), 0019 (CSRF, profile reset), 0020 (reflected XSS via Feedback activity import errors), 0022 (CSRF, group messaging toggle), 0023 (CSRF, quiz section headings), 0024 (missing capability check, AI placement web services), 0027 (blind SSRF via MNet peers), 0029 (missing capability check, report builder fragment callbacks). |
| **5.0.9** | 8–10 Aug 2026 | Unknown count. 5.0.9's own release notes say only: "A number of security related issues were resolved. Details of these issues will be released after a period of approximately one week." I checked both [moodle.org/security](https://moodle.org/security/) and the [security-announcements forum](https://moodle.org/mod/forum/view.php?id=7128) on 2026-09-08 — nothing beyond the 22 June 2026 batch (which is the 5.0.8 set above) has been posted. That's roughly four weeks past the promised one-week disclosure window. I can't tell whether that's a genuine delay on Moodle's side or a gap in what I could fetch; either way, **5.0.9's security content is unconfirmed as of this report** and should be re-checked before acting on it. |

Two items fixed elsewhere in this window but **not** in any 5.0.x release —
included for completeness since their MSA numbers fall inside this range:
MSA-26-0004 (Symfony process library, Windows-only command injection, fixed
only in 4.5.9) and MSA-26-0008 (PHPUnit upgrade, a CI/testing-only concern,
fixed only in 4.5.11). Neither applies to this Linux-hosted 5.0.x site.

## 3. Which of these actually reach this site

I read `.cicat/CUSTOMIZATIONS.md` and the vendored `theme/adaptable` source
(read-only, per the task rules) to weigh relevance. I did **not** have — and
this task doesn't permit — access to the live database or admin settings
panel, so anything gated by an admin-configurable "is this subsystem enabled"
flag (auth method, repository type, filter on/off) can't be confirmed from the
code tree alone. That limits what follows to reasoned inference, flagged as
such.

**Clearly reachable regardless of configuration**, because they're core
teaching-workflow features with no off-switch on an active platform, and this
is a live student site issuing certificates off completions and grades
(`local_certengine`, `local_certpreissue`):

- **MSA-26-0021** (Serious, grade item CSRF/XSS), **MSA-26-0025** (Serious,
  quiz regrade CSRF), **MSA-26-0026** (Serious, assignment marker allocation),
  **MSA-26-0028** (Serious, profile-description DoS) — gradebook, quiz, and
  assignment are exactly the subsystems the certificate pipeline depends on.
- **MSA-26-0001** (Serious, RCE via file restore) and **MSA-26-0014** (Serious,
  arbitrary file read via backup restore) — Moodle's course backup/restore is
  a default-on core feature teachers and admins use routinely (course
  duplication, restoring from a previous term); nothing in
  `CUSTOMIZATIONS.md` suggests it's disabled or restricted.

**Flagged by CICAT's own documentation, enablement unconfirmed:**

- **MSA-26-0002** (Serious, RCE in the TeX filter's admin setting — requires
  admin access and ImageMagick) and **MSA-26-0003** (Serious, DoS in the TeX
  formula editor). `CUSTOMIZATIONS.md` §7 independently flags this exact
  filter: the `mimetex.*` binaries under `filter/tex/` have lost their
  executable bit in production, and the doc says plainly "if that filter is
  enabled in Moodle, it is currently broken in production." I can't tell from
  the code tree whether `filter_tex` is enabled site-wide — that's a database
  setting — but given CICAT's own doc already treats this filter's status as
  an open question, whoever answers it should check both things (is it
  enabled, and does a broken mimetex binary limit the actual RCE surface) at
  the same time.

**Plausible but unconfirmed** (the code path exists in vendored core; whether
each is turned on for this site is unknown to me):

- MSA-26-0006 (RCE via Google Drive repository plugin) — depends on whether
  the `googledocs` repository type is enabled.
- MSA-26-0005 (SQL injection in `auth_db`) — depends on the site's
  authentication method; the presence of `local_panel_secretaria` (a
  secretariat panel for manual user administration) suggests native/manual
  accounts rather than an external-DB auth bridge, but that's an inference,
  not a confirmed negative.
- MSA-26-0013 (email-MFA bypass) — depends on whether Moodle's built-in MFA
  is turned on.
- MSA-26-0012 (arbitrary file read via mod_data import) — depends on whether
  Database activities are used in any course.
- MSA-26-0015 (RCE via admin presets import) — requires existing admin access
  to exploit, so it mainly matters as defense-in-depth; worth noting that
  `user/editadvanced.php` is patched to route the secretariat role through a
  custom panel, which is a second place with elevated user-editing reach
  worth keeping in mind when scoping who effectively holds admin-adjacent
  capability.
- The remaining Minor CSRF/XSS items (MNet peers/admin settings, quiz section
  headings, group messaging toggle, homepage preference, profile reset,
  Feedback import, report builder fragments, AI placement web services) — no
  evidence either way on enablement; listed for completeness, not weighted
  heavily given they're all Minor and several require a feature
  (MNet peering, AI placement, report builder) this site shows no sign of
  using.

Nothing in the disclosed set targets `mod_customcert`, `mod_zoom`,
`filter_generico`, `availability_role`, or TCPDF directly — the four
subsystems CICAT has most heavily customized or patched.

## 4. Support status

From [moodledev.io/general/releases](https://moodledev.io/general/releases)
(docs.moodle.org/dev/Releases now redirects here — I checked, and it names this
page as the current source, so I'm treating it as the primary official record):

| Branch | Type | Released | General support ends | Security support ends |
|---|---|---|---|---|
| 4.5 (predecessor) | LTS | 7 Oct 2024 | 6 Oct 2025 | 4 Oct 2027 |
| **5.0 (this tree)** | Standard | 14 Apr 2025 | 20 Apr 2026 (passed) | **5 Oct 2026** |
| 5.1 | Standard | 6 Oct 2025 | 5 Oct 2026 | 19 Apr 2027 |
| 5.2 | Standard | 20 Apr 2026 | 19 Apr 2027 | 4 Oct 2027 |
| 5.3 | **LTS** | 5 Oct 2026 (scheduled, not yet released) | 4 Oct 2027 | 1 Oct 2029 |

5.0 is already past general support (no more non-security bug fixes; 5.0.7
through 5.0.9 are security-only releases). Security support ends **5 October
2026 — about four weeks from today**. After that date, this branch gets
nothing at all, including for any future critical RCE. 5.3, the next
long-term-support release, is scheduled for the same week 5.0's security
support ends; it isn't out yet, so it can't be evaluated further here, but its
5-year-equivalent security window (through October 2029) is the standout
option if the captain wants to upgrade once rather than twice. Staying on 5.0
buys at most a few weeks; the practical choice is between 5.1/5.2 now or
waiting for 5.3.

## 5. Does anything in this range need more than tree-replace + upgrade.php?

**No PHP or database requirement change** was found anywhere in the 5.0
branch's lifetime, including this gap. Minimum PHP stays 8.2.0 across all of
5.0.x (confirmed via [moodledev.io/docs/5.0/gettingstarted/requirements](https://moodledev.io/docs/5.0/gettingstarted/requirements)
and release-note review of 5.0.5–5.0.9); it only rises to 8.3.0 at 5.2, outside
the 5.0 line. Oracle support was dropped in 5.0.0, before this tree's baseline,
so it's not a new consideration.

**One manual-step flag, already resolved by the time you'd apply it:** 5.0.5
shipped a regression, [MDL-87892](https://moodle.org/mod/forum/discuss.php?d=468256),
that broke site-administration access for any third-party theme overriding
Moodle's `core_admin_renderer` class (Moodle names Moove as the example).
Moodle's own 5.0.5 release notes tell affected sites to skip 5.0.5 entirely and
go straight to 5.0.6, where it's fixed. I checked this tree's `theme_adaptable`
source: it overrides `core_renderer` and several component renderers
(`theme/adaptable/classes/output/core_renderer.php` and siblings) and has a
`templates/core_admin/settings.mustache` template override, but defines no
`core_admin_renderer` class override — so on the evidence here, this site's
theme is not expected to hit that regression. Moot in practice either way,
since 5.0.6 is two days behind 5.0.5 and includes the fix — there's no reason
to ever stop on 5.0.5 alone.

No other upgrade note in 5.0.5 through 5.0.9 flags a manual step beyond
replacing the tree and running `admin/cli/upgrade.php`, based on the release
and upgrade notes reviewed for each point release.

Not part of this question's scope, but worth restating since it bears on any
future upgrade of *those specific plugins* (not the core version bump covered
here): `CUSTOMIZATIONS.md` already documents that `mod_customcert` carries four
non-upstream elements and the four custom TCPDF font families that must be
manually re-applied whenever those specific pieces are upgraded. That's an
existing, already-documented constraint, not something new this review found.

## Second problem?

None found beyond what CICAT's own `CUSTOMIZATIONS.md` already documents (the
mimetex executable-bit issue in §7, which I cross-referenced against MSA-26-0002/
-0003 above but didn't newly discover). No separate task is being opened from
this scout.
