# Shape: owning the runtime

A step back taken before committing to the Moodle upgrade sequence in
`rebuild-shape.md` §7. The captain's direction was to stop accommodating
aaPanel and look at the architecture first. This note argues that the
deployment shape is not a chore that precedes the rebuild. It is the mechanism
the rebuild depends on, and it is also what makes the upgrade safe.

## 1. The number that frames it

`cicat/classroom` tracks **29,844 files**.

| What | Files |
|---|---|
| CICAT-authored code (3 local plugins, 4 customcert elements) | 79 |
| Third-party plugins (adaptable, customcert, zoom, generico, availability_role) | 753 |
| Patched lines in Moodle core | 2 |
| Pristine, unmodified vendored Moodle core | ~29,000 |

`.cicat/CUSTOMIZATIONS.md` states the reason for vendoring plainly, and it is
honest about it:

> They are the reason this repository vendors the full Moodle tree rather than
> tracking `local/` alone: a customizations-only repository would lose both on
> the next upgrade without anyone noticing.

Twenty-nine thousand files are tracked so that a merge conflict will notice two
lines. That is version control standing in for a build step.

## 2. Six problems, one cause

Everything currently painful descends from a single decision: the repository is
the docroot.

1. **The upgrade treadmill.** A core upgrade means re-vendoring the whole tree
   and replaying customizations through a merge across 29,000 files. The merge
   is the only thing protecting the two core patches, and `CUSTOMIZATIONS.md`
   already admits it is "demonstrably incomplete".
2. **Deployment needs write access to a live docroot.** `DEPLOY.md` blocker 1
   is that nobody on the team can write to it, with a shared-group and setgid
   ritual proposed to fix it.
3. **`.git` sits inside the docroot**, so the webserver needs a rule to stop
   the internet reading it.
4. **The `config.php` dance.** Six vendored `config.php` files have to be
   excluded by an anchored rsync pattern, and getting the anchor wrong ships
   them.
5. **Agents need a read-only rule** covering 29,844 files, enforced by
   convention rather than by structure.
6. **Production's PHP version is whatever the panel provides**, which is why it
   is unknown, and why I asked the captain to go and measure it.

Item 6 is the one that prompted this note. It is not a fact worth measuring. It
is a question that only exists while something else owns the runtime.

## 3. The proposal

Three changes, and they are one change.

**The repository holds CICAT's code.** Moodle core becomes a pinned build
input, downloaded at image build time rather than committed. Third-party
plugins likewise, at pinned versions. The repository shrinks to the 79 files
that are actually ours, plus the plugin pins, plus the stack definition.

**The two core patches become real patch files** applied at build. Today they
survive because a human notices a merge conflict. As patches they either apply
or the build fails, loudly, at the moment of the upgrade. A build that refuses
to produce an image beats a merge that silently drops a line.

**The deliverable is an image, not a file tree.** CI builds it, the server
pulls it. Deployment stops being rsync onto a live docroot, which removes
problems 2, 3 and 4 outright. Rollback becomes the previous tag.

`.devstack` already describes this stack. It becomes the production definition
rather than a development convenience, and dev/prod parity stops being a thing
we maintain and becomes a thing that is true by construction.

## 4. Restructure at the current version, then upgrade

Three orders are available, and the obvious two are both worse than the third.

**Upgrade first, restructure later** pays the re-vendoring cost twice, and the
second payment lands on a tree that has just been disturbed.

**Restructure and upgrade in one move** pays it once, but leaves nothing to
check the result against. If the built image misbehaves, the restructure and the
version change are both suspects and neither can be ruled out.

**Restructure at 5.0.4, then upgrade** pays nothing, because the current tree is
the reference. A build that assembles Moodle 5.0.4, our plugins and the two
patches can be diffed against the tree already committed, and the acceptance
test is that they match. That is a provable claim rather than a judgement. Once
it holds, the upgrade is a change to one version argument, and any behaviour
change afterwards has exactly one possible cause.

This supersedes an earlier draft of this section, which argued for doing the
restructure during the upgrade. Working through the execution order showed the
reference tree is worth more than the saved pass.

## 5. The argument that actually decides it

R1 in `rebuild-shape.md` is the hardest constraint in the whole plan: every
certificate already in circulation carries a printed URL under
`/mod/customcert/verify_certificate.php`, and that path must resolve forever.

Shape B, the strangler, satisfies R1 by moving that one route to the new
application early while Moodle keeps everything else. That plan requires a
routing layer that can be versioned, reviewed, tested locally and rolled back.

Under aaPanel, routing is a vhost edited by hand through a web UI. It cannot be
diffed, it cannot be tested before it is live, and it is not in the repository.
**A strangler cannot be built on a seam that cannot be versioned.** Owning the
proxy is not tidiness. It is the precondition for the rebuild that has already
been chosen.

## 6. The real risk, and why this lowers it

Naming the cost honestly: moving production onto containers roughly three weeks
before Moodle 5.0 loses security support means two changes in one window, on a
live site, and that is a genuine reason for concern.

The mitigation is available only because of containers, which is what makes this
an argument for the change rather than against it:

1. Bring the container stack up on the same VPS, on a port nobody uses.
2. Restore the sanitised snapshot into it.
3. Run the core upgrade inside it. Verify with `mise run check` and
   `mise run check:certificate`.
4. Flip the proxy when it passes.

The aaPanel site keeps serving, untouched, until step 4. Rollback is flipping
back. None of that rehearsal is possible today, which is the point: the current
architecture is why the upgrade feels dangerous.

## 7. Revised order for §7 of rebuild-shape.md

| | Was | Now |
|---|---|---|
| 0 | | Own the runtime: containerised production, proxy seam, image deploy |
| 1 | Moodle upgrade to 5.3 | Moodle upgrade, done as the restructure (core as build input) |
| 2 | Resolve S5 | unchanged |
| 3 | Capability gap in the secretariat panel | unchanged, and independent of all of this |
| 4 | Scaffold Nuxt | unchanged, now has a seam to attach to |

The 5.3 target in the original §7 was written before 5.3's release date was
weighed against its being a `.0`. Target selection is a separate decision from
this note and is not settled here.

## 8. What a greenfield build would have done differently

Written after the captain asked whether this proposal is actually what I would
have built from scratch. Three of these are not addressed by §3, and the first
is permanent.

**The verification URL would not name the implementation.** Certificates in
circulation carry `/mod/customcert/verify_certificate.php`, so a third-party
plugin's filename is now a permanent public contract. A path we owned from the
start, `/verify/<code>` or a separate short domain, would have cost nothing then
and would have made the strangler a routing detail rather than the constraint
the whole plan bends around. This cannot be undone, only contained, and §5 is
the containment.

**`local_certengine` would not read `mod_customcert`'s tables.** Twelve files in
the engine query `customcert_issues`, `customcert_templates`, `customcert_pages`,
`customcert_options` and `customcert_printmode` directly. That is a schema
dependency on a third-party plugin, not an API one. A greenfield engine would
render its own certificates, which would also remove the four bespoke elements
from inside `mod/customcert` and with them the extraction hazard that
`rebuild-shape.md` §3 shape A exists to address.

This has an immediate consequence. The `customcert` upgrade brief treats
`check:certificate` as the guard that makes the upgrade safe. It is not
sufficient: it renders through customcert, so an upstream schema change that
breaks certengine's direct queries can pass it. Amend that brief before the task
runs.

**There would be plugin CI.** `.github/workflows/` holds one file, `deploy.yml`.
`moodle-plugin-ci` is the standard harness for Moodle plugin work and nothing
here uses it.

**There would be backups.** `.cicat/DEPLOY.md` states plainly that this scheme
has none. For a system whose hardest requirement is that certificates verify
permanently, loss of the database violates R1 in a way no upgrade can. This is a
larger exposure than version currency and it belongs in phase 0.

Backups and the upgrade rehearsal want the same machinery. Standing the stack
up, restoring a dump into it and verifying is both the rehearsal in §6 and the
proof that a restore works. Building it once earns both guarantees.

## 9. Effect on work in flight

- **`snapshot`** matters more, not less. It is the data that fills the
  container for the rehearsal in §6. No change to its brief.
- **`devstack-ports`** matters more. If `.devstack` becomes the production
  definition, per-checkout correctness stops being a developer convenience.
- **`customcert`** changes shape. Its stated purpose was to rehearse
  re-applying the CICAT layer over an upstream drop. Under an overlay build that
  procedure is the build itself, so the task becomes the first test of the new
  structure rather than a manual rehearsal of the old one.
- **The secretariat capability fix** is untouched by any of this and should
  proceed regardless.
