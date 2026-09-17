Outcome: three structurally different real-screenshot prototypes exploring how much of
today's always-visible sidebar (camera source, resolution, rotate, zoom, phone picker,
name search, manual DNI entry, F1/F2/Esc hint) should move out of the main operating view,
versus stay. This is a throwaway prototype (same mechanism as the earlier `ui-prototype`
task: `xvfb-run` + a screenshot script against the real `App`, stubbed I/O, fake data — see
`notes/windows/briefs/ui-prototype.md` for the exact mechanism, reuse it).

Why: the captain's own words after seeing the real running app (with the now-merged
`sv_ttk` theme applied): "ui looks like its from a 2000 program! very verbose and has a
lot of buttons! not a big fan of this design." Confirmed by inspection: the sidebar always
shows 5 camera fields + phone picker + name search + manual DNI entry + register button +
hint text, all at once, all the time — every session, whether or not the operator needs to
touch any of it. The theme change (merged) fixed color/flatness, not this. This is now a
density/information-architecture question, not a palette one.

Read first: current `app/ui.py` (post-merge, includes the sidebar layout and sv_ttk theme)
in full, and `notes/windows/briefs/ui-sidebar-layout.md` / `ui-prototype.md` for what was
already tried and rejected as insufficient.

## Three variants (structurally different, not re-skins)

- **A — Settings dialog**: default view shows ONLY: a compact header, the video feed, the
  result banner, "Últimas lecturas" table, and one visible action for manual
  registration (a single button that reveals name-search/DNI entry, e.g. opens a small
  panel or dialog on demand — your call on modal vs. inline-reveal, but it must not be
  permanently visible). Camera source/resolution/rotate/zoom/phone selection move into a
  separate settings surface opened by a single gear/"Configuración" affordance — a Toplevel
  dialog is fine for this, since it's used once at setup, not continuously.
- **B — Minimal always-visible bar**: keep a single slim top or bottom bar with only the
  camera connection status (read-only text, e.g. "Pixel 8 · USB · listo") and one
  "Configuración" button that opens everything else (camera + phone settings) in a dialog.
  Manual registration stays as a single always-visible compact row (just the name-search
  combobox, no separate DNI field shown until needed) since that's used during normal
  operation, not just setup.
- **C — Progressive disclosure sidebar**: keep the sidebar, but collapse the "Cámara" group
  by default (starts collapsed after first successful connection, expandable by clicking
  its header) while "Registrar" stays open since it's used continuously. This is the
  smallest structural change of the three — include it as the conservative option.

Across all three: cut visible text wherever a label repeats what's obvious from context
(e.g. does "Resolución:" need to be a separate label from the combobox, or can placeholder
text carry it), and reduce hint text (the F1/F2/Esc line) to something less prominent than
a permanent full sentence, without deleting the functionality it documents.

## Constraints

- Same throwaway rules as before: do not modify the real `app/ui.py`. Build the variants in
  a prototype script, capture PNGs, report paths. Nothing here gets folded in without the
  captain picking one first.
- Keep every existing keybinding/command working in spirit (F1/F2/F5/F6/Esc, reconectar,
  cambiar cámara/resolución/rotación/zoom, buscar por nombre, registrar manual) — moving a
  control into a dialog is fine, removing the capability is not.
- Spanish copy, matching existing tone. Keep the sv_ttk theme applied (it's merged now,
  use it in the prototype for an accurate picture).
- Use realistic fake data (a few Registro rows, all four states: ENTRADA/SALIDA/DUPLICADO/
  DESCONOCIDO) so density is judged with real content, not an empty mockup.

Evidence: three PNG screenshots (one per variant, full window, realistic data). If a
variant involves a dialog/popup (A and B's settings dialog), capture that dialog open in a
second screenshot for that variant so the captain can see both states. Report every
screenshot's absolute path with a one-line note on what's structurally different. This is
scout-adjacent but keep it as a normal ship task (like the first ui-prototype) since it
still needs `cap check`/inspection of the throwaway script quality — do not commit
anything.
