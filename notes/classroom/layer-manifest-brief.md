# Establish what CICAT actually changed on top of Moodle 5.0.4

This repository is the docroot of https://aulavirtual.cicat.edu.pe, a live
Moodle 5.0.4 site. Nothing here deploys on merge. Read `README.md`,
`.cicat/CUSTOMIZATIONS.md` and `.cicat/LOCAL-ENV.md` first.

You are producing a document and evidence. You are not changing how anything
builds or runs. Resist that. A later task does it, and depends on this one
being right.

## Why this exists

The repository tracks 29,844 files. About 29,000 of them are pristine Moodle
core, tracked only so that a merge conflict will notice the two lines CICAT
patched. A later task replaces that with a build: Moodle core and third-party
plugins become pinned inputs, and this repository keeps CICAT's own code plus
the patches.

That build is safe only if the list of what CICAT changed is complete.
`.cicat/CUSTOMIZATIONS.md` is the current answer, and it describes itself as
produced by diffing the live docroot against the 5.0.4 tarball. Other notes
here call it demonstrably incomplete. A missed modification does not fail
loudly under the new build. It silently reverts to upstream, on a live site,
and the first sign is a workflow that stopped working.

## What to produce

A complete, evidence-backed manifest of every difference between this tree and
pristine upstream, at `.cicat/LAYER.md`.

Cover all four categories, and treat each as a question rather than assuming
the existing document's answer.

1. **Moodle core.** `CUSTOMIZATIONS.md` claims exactly two patched files,
   `lib/classes/router.php` and `user/editadvanced.php`. Verify that against
   the real 5.0.4 release, file by file, across the whole core tree. Report
   every difference, including ones that look accidental: stray files, deleted
   files, permission changes, line-ending changes.
2. **Third-party plugins.** `theme/adaptable`, `mod/customcert`, `mod/zoom`,
   `filter/generico` and `availability/condition/role`. Each is supposed to be
   an unmodified upstream release. Establish the exact upstream version of each
   from its own `version.php`, fetch that version, and diff. A CICAT edit
   hiding inside one of these is the single most likely thing the existing
   document misses, because nothing in the repository would reveal it.
3. **CICAT's own plugins.** `local/certengine`, `local/certpreissue`,
   `local/panel_secretaria`, and the four customcert elements `autofitname`,
   `cargogrupo`, `ceasset` and `cetext`. These are ours entirely. List them
   and their file counts. No diff is needed.
4. **Deliberate deletions.** Commit 851ecb38 removed upstream's GitHub
   workflows. Find anything else upstream ships that this tree does not, and
   say whether each looks deliberate.

## How to be sure

Do not diff against a tarball you cannot name. State exactly which upstream
artefact you compared against and how you obtained it, so someone else can
repeat the comparison and get the same answer.

The vendored tree is read-only for you. Do the comparison in a scratch
directory outside this repository.

Where a file differs, quote the actual difference. "Modified" is not a
finding, it is a place to look. For each one, say whether it is a deliberate
CICAT change, accidental drift, or something you could not classify. The third
is a real answer and is worth more than a confident guess.

## Deliverable

`.cicat/LAYER.md`, and nothing else changed. It should let a reader rebuild
this docroot from upstream inputs plus the contents of that document, and know
when they have finished.

Say plainly, in its own section, where `.cicat/CUSTOMIZATIONS.md` is wrong or
incomplete. Do not edit that file. A later task reconciles the two.

## Verification

`mise run check` and `mise run check:certificate` exit 0, which here only
proves you did not disturb the tree.

The real verification is different. Take pristine upstream 5.0.4 in a scratch
directory, apply everything your manifest describes, and diff the result
against this repository's tracked tree. Every remaining difference is either a
gap in your manifest or something the manifest must explain. Report that
diff's final state. If it is not empty, say exactly what is left and why.
