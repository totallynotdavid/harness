# Shape: replacing the Moodle classroom with Nuxt

Shaping the captain's request to phase out `cicat/classroom` (Moodle 5.0.4) in favour of a
clean Nuxt application. Fires because there is more than one plausible mechanism and
getting it wrong is expensive: certificate verification codes are permanent public
artifacts.

Evidence behind this note lives in four sibling reports: `rebuild-scope.md` (what the site
actually does), `nuxt-references.md` (mature Nuxt repositories), `nuxt-stack-2026.md`
(current versions and stack decisions), and `design-language.md` (the makingsoftware.com
aesthetic).

## 0. The forcing function is not the rebuild

Moodle 5.0 security support ends **5 October 2026**, roughly four weeks out
(`moodle-509-disclosure.md`). The tree is at 5.0.4, five point releases behind, with two
Serious RCEs and an `auth_db` SQL injection in the gap (`moodle-currency.md`).

No rebuild lands in four weeks. So the Moodle upgrade is not an alternative to the
rebuild, it is a prerequisite that happens regardless. This note shapes the rebuild; the
upgrade is separate work that starts now.

## 1. Requirements

| | Requirement | Status |
|---|---|---|
| R1 | Every already-issued certificate keeps verifying at the URL printed on it, permanently. | known |
| R2 | Reissued and newly issued certificates render with the same typefaces and layout as the ones already in circulation. | known, with a licence spike |
| R3 | Certificates can be generated with their definitive verification code before the exam exists, and released automatically when the student passes. | known |
| R4 | Secretariat staff administer certificates across all courses without a developer. | known |
| R5 | External, non-enrolled people (speakers, organisers) receive certificates without ever logging in. | known |
| R6 | Student personal data handling satisfies Ley 29733 as amended by DS 016-2024-JUS. | spike |
| R7 | The public site runs on security-supported software after 5 October 2026. | known |
| R8 | Course delivery with quiz-gated certificate eligibility continues. | known |
| R9 | Physical certificate requests are captured and their fulfilment tracked. | known |
| R10 | Live sessions (currently Zoom) continue to be scheduled and joined from the course. | known |

## 2. Spikes

**S1. Where do printed QR codes point?** Resolved by reading.
`mod/customcert/verify_certificate.php` is the public verification entry point, and
`mod/customcert/element/qrcode` renders the code into the PDF. Every certificate already
in circulation carries a URL under
`https://aulavirtual.cicat.edu.pe/mod/customcert/verify_certificate.php`. That path must
resolve forever, whatever runs behind it. This is the hardest constraint in the note and
it is cheap to satisfy if planned, and impossible to satisfy retroactively.

**S2. What are the four custom fonts?** Resolved by reading, and closed by the captain.
The TCPDF descriptors name them: `dinpro_b` is **DINPro-Bold**, `dinpro_medium` is
**DINPro-Medium**, `scriptmtb` is **ScriptMTBold**, and `scriptmtbmod` is a modified
derivative. All are commercial retail typefaces (DIN Pro from Monotype/FontFont, Script MT
Bold ships with Office), so web-font use needs licences CICAT may not currently hold.

**The captain has decided this is a purchasing line item, not a design constraint.**
Licences will be bought. Planning and development proceed on the assumption that the
fonts are available as web fonts. This no longer gates the PDF renderer decision, which is
settled in `aula-design.md`: headless browser, HTML to PDF.

**S3. Does Ley 29733 mandate in-country residency?** Not resolvable from the repository.
Needs counsel. Decides whether hosting must be physically in Peru or merely regional.

**S4. Is better-auth's SAML and SCIM tier free and self-hostable?** Not resolvable from the
repository; the vendor docs are ambiguous. Only blocks the institutional SSO requirement,
which is not day one. Deferred, not blocking.

**S5. Do the courses carry real teaching, or only certificate gating?** Not resolvable from
the repository. `rebuild-scope.md` establishes that only the gating role is proven by
code. Needs a live database query. **This is the single spike that most changes the
answer below**, because it decides whether R8 means "keep a full LMS" or "keep a quiz".

## 3. Shapes

**A. Stay on Moodle.** Upgrade to 5.3 (released 5 October 2026), split the four
CICAT-authored customcert elements into their own plugin so the extraction hazard goes
away, and re-apply the two undocumented core patches deliberately. Cost: the upgrade
treadmill continues forever, and the certificate work stays wedged inside a third-party
plugin. Forecloses nothing.

**B. Strangler.** A new Nuxt application owns certificates end to end: the domain model,
issuance, pre-issue, verification, the secretariat console, and physical fulfilment.
Moodle keeps courses, quizzes and enrolment, and becomes an upstream source of completion
events consumed over its web service API. The verification URL is redirected from Moodle to
the new app early. Cost: two systems to run and an integration boundary where an in-process
event observer used to be. Forecloses nothing; Moodle can be retired later or never.

**C. Big-bang replacement.** Nuxt owns courses, quizzes, enrolment, grading, live sessions
and certificates. Moodle is retired in one cut. Cost: rebuilding a quiz engine, a
gradebook, and an enrolment model, none of which contain any CICAT-specific value.
Forecloses a staged migration, and puts R1 at maximum risk by moving everything at once.

**D. Different off-the-shelf LMS.** Replace Moodle with another platform and rebuild the
certificate engine as a plugin for it. Cost: a new plugin API to learn, the same
certificate work as B, and a migration of course content. Forecloses little but buys
little.

## 4. The cross

| | A stay | B strangler | C big bang | D other LMS |
|---|---|---|---|---|
| R1 verification URL survives | ✓ | ✓ redirect planned from day one | ✗ highest risk, everything moves at once | ~ depends on the new platform's routing |
| R2 render fidelity | ✓ unchanged TCPDF | ~ new renderer, gated on S2 | ~ same as B | ~ same as B |
| R3 pre-issue workflow | ✓ exists | ✓ rebuilt cleanly, no transient-row trick | ✓ | ✗ rebuild against an unknown plugin API |
| R4 secretariat console | ✓ exists | ✓ the main prize | ✓ | ~ |
| R5 external recipients | ✓ exists | ✓ | ✓ | ~ |
| R6 Ley 29733 | ~ unchanged posture | ~ improved, still gated on S3 | ~ | ~ |
| R7 supported after 5 Oct | ✓ via 5.3 upgrade | ✓ Moodle still upgraded | ✗ cannot ship in four weeks | ✗ cannot ship in four weeks |
| R8 course and quiz gating | ✓ | ✓ Moodle keeps it | ✗ must rebuild a quiz engine | ✓ |
| R9 physical fulfilment | ~ works, on a Feedback hack | ✓ first-class entity | ✓ | ~ |
| R10 live sessions | ✓ mod_zoom | ✓ Moodle keeps it | ✗ rebuild the Zoom integration | ~ |

**The pick: A now, then B.** They are not competing. A is forced by R7 and starts
immediately; B is the rebuild.

**The requirement that decided it: R7 crossed with R8.** R7 rules out C and D outright,
because neither ships in four weeks. R8 then separates B from C: `rebuild-scope.md`
establishes that every line of CICAT-authored code serves certificates, and that courses
and quizzes are stock Moodle used only as gates. Rebuilding a quiz engine and a gradebook
buys nothing CICAT does not already have working.

**What the pick gives up.** Two systems to run for as long as the strangler lasts, and the
release trigger becomes a network call instead of an in-process event observer, which is
strictly less reliable and needs its own retry and reconciliation design. B also does not
retire Moodle, so the upgrade treadmill continues on the course side. That is a real cost
and it should be named rather than assumed away.

**What would break the tie toward C.** If S5 comes back saying the courses carry no real
teaching, that quizzes exist only to gate certificates, then C's cost collapses, because
"rebuild a quiz engine" becomes "rebuild a pass/fail assessment", and B's two-system
overhead stops being worth paying. Resolve S5 before committing to B's integration work.

## 5. Stack, if B proceeds

From `nuxt-stack-2026.md`, with costs named there: Nuxt 4.5.x with the `app/` directory,
plain Nitro routes with Zod, Drizzle on the stable 0.45.x line over Postgres, better-auth
self-hosted, reka-ui with Tailwind v4 hand-styled rather than a component kit, self-hosted
Docker on a VPS in or near Peru, Vitest over server logic with a thin Playwright happy
path.

Two cross-cutting notes the individual reports do not carry on their own:

- The reference repositories converge on NuxtHub and Cloudflare Workers as a deploy
  target, but NuxtHub's hosted product is being wound down and Workers cannot run Postgres
  without Hyperdrive proxying to an external database. Popularity in that sample is a
  lagging indicator. Self-hosted Docker is the right call here independently of the
  residency question in S3.
- The PDF renderer is settled: headless browser rendering HTML to PDF. S2 is closed, the
  licences are being bought, and PDFKit's hand-computed coordinate layout is no longer a
  fallback worth holding open.

## 6. Design direction

From `design-language.md`. The four moves that carry the aesthetic: an off-white and
off-black base pair rather than pure black and white; a monospace face used for UI chrome,
labels and metadata rather than only for code; a tight contact shadow with an inset white
highlight reserved for genuinely elevated surfaces, with flat 1px borders everywhere else;
and a near-invisible accent-tinted hairline texture on large empty regions. Radius ceiling
around 6px.

Where it must bend: this is an application with tables and forms, not a reading site. The
65ch measure applies to prose surfaces only, the card shadow cannot ride on 200 table rows,
and the bespoke interactive diagrams that carry most of makingsoftware.com's authored
feeling are not a transferable pattern.

## 7. What starts now, in order

1. The Moodle upgrade path to 5.3, independent of everything else here. Before it,
   diff the full `mod/customcert` tree against a clean 5.0.3 tarball, because
   `.cicat/CUSTOMIZATIONS.md` is demonstrably incomplete and an overwrite upgrade silently
   drops the blank-grade patch that the whole pre-print workflow depends on.
2. Resolve S5 (do courses carry teaching). S2 is closed: licences are being bought.
3. Fix the capability gap found in passing: deleting an issued certificate in the
   secretariat panel is guarded by `local/panel_secretaria:view`, the read capability.
4. Only then, scaffold the Nuxt application.
