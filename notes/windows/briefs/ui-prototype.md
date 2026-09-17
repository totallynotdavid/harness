Outcome: three structurally different layouts for the main window (`app/ui.py`'s `App`
class), each rendered as a real screenshot the captain can actually look at, so a layout
gets picked on sight instead of by description. This is a throwaway prototype (see the
`prototype`/`UI.md` pattern) adapted for a Tk desktop app: there's no route or `?variant=`
param here, so the equivalent is one runnable script that mounts each variant against
stubbed data and captures it headless.

Why this is needed now: the current window crams camera source, resolution, rotation,
zoom, reconnect, name-search, and manual-DNI-entry into two thin horizontal toolbars
(`app/ui.py` lines ~140-202) — everything competes for the same strip, nothing has visual
hierarchy. That's the concrete complaint ("ui looks bad"), not a vague aesthetics ask.

Read first: the whole of `app/ui.py`'s `App.__init__` (build order, current widget tree,
`COLORES`, fonts already in use) and `app/models.py` (`ENTRADA`/`SALIDA`/`DUPLICADO`/
`DESCONOCIDO`) so variants use real states, real Spanish copy, and the app's existing
color language — not invented colors or English placeholder text.

## Mechanism (must be exact, this is what makes the screenshots trustworthy)

- Write a throwaway script, e.g. `app/_ui_prototype.py` (name it obviously a prototype;
  it never ships — see below), that builds `App` (or a thin variant subclass/parameter)
  three different ways and renders each to a PNG.
- Stub every external dependency the real `App.__init__` currently requires (camera
  worker, Android/ADB detection, Excel/openpyxl backend, roster file, SUNAT HTTP call) —
  the prototype must not touch a real camera, Excel file, or network. Feed it fabricated
  but realistic data: a few `Registro`-shaped rows for "Últimas lecturas", a fake roster
  with a handful of names for the name-search box, one of each attendance state
  (ENTRADA/SALIDA/DUPLICADO/DESCONOCIDO) so color and copy are visible in the screenshot.
- Render each variant under `xvfb-run` (already available in this environment) and save a
  PNG with e.g. `self.update_idletasks(); self.after(300, capture)` then `import -window
  <id> variant-a.png` (ImageMagick's `import` is available), or Tk's own
  `postscript()` + convert if that proves more reliable — verify whichever you pick
  actually produces a non-blank, correctly-sized PNG before trusting it, don't assume.
- Save the three PNGs into `notes/windows/scratch/` in this captain repo (NOT the windows
  repo — screenshots are a review artifact, not a deliverable) — wait, you can't write
  outside your own worktree. Instead: save them inside your worktree under a clearly
  scratch path (e.g. `.prototype-screenshots/`, gitignored) and report the absolute paths
  in your final message; the captain will copy them out for review.

## Three variants, structurally different (not re-skins)

Pick three real layout strategies, e.g.:
- **A — grouped toolbar**: camera/video controls in one labeled group (LabelFrame),
  identification actions (name search, manual DNI, register) in a visually separate
  group, instead of one flat row.
- **B — sidebar**: move all controls (camera + identification) into a left or right
  sidebar column next to the video, freeing the top for just status/title.
- **C — tabbed/collapsed**: keep camera controls always visible (needed continuously),
  but move the less-frequent identification/manual-entry actions behind a single
  always-visible but visually secondary affordance (e.g. a distinct bordered panel below
  the video, not fighting the toolbar).

Use your judgment on the exact three — the point is real structural disagreement (per
`UI.md`'s anti-pattern list: no variant that only changes colors/spacing). Keep every
variant's actual widget *behavior* wired the same as today (same commands, same state
names) — only layout/grouping changes, since this is a layout question, not a rewrite.

## Constraints

- Throwaway: do not modify `app/ui.py` itself. The prototype script imports from it or
  duplicates only what's needed to vary layout — capture the winner into `app/ui.py` in a
  follow-up task once the captain picks, don't do that here.
- No persistence, no real I/O, no network (SUNAT), no real camera/Excel.
- Spanish copy throughout, matching the app's existing tone (`rules/comments.md`'s "write
  plainly" applies to UI copy too, not just comments).

Evidence: three PNG screenshots, one per variant, each showing the full window with
realistic fake data in every region (video placeholder, banner state, últimas lecturas
table, all controls). Report each screenshot's absolute path and a one-line description of
what's structurally different about it. If headless screenshot capture turns out not to
work in this environment (verify, don't assume it will and skip evidence), report that
directly as a blocker rather than describing the variants in prose only — the captain
needs to see pixels, not read a description.
