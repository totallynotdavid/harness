Outcome: `app/ui.py`'s `App` window uses a left sidebar for all controls (camera +
identification), with the video feed and the results panel (banner + últimas lecturas
table) occupying the rest of the window. This is the real implementation of "Variant B"
from the throwaway prototype at `notes/windows/briefs/ui-prototype.md` (already reviewed
via real screenshots and picked by the captain) — build it directly in `app/ui.py`, not as
another prototype.

Why: today's layout crams camera source, resolution, rotation, zoom, reconnect,
name-search, and manual-DNI-entry into two thin horizontal toolbars (current
`app/ui.py` lines ~140-202), leaving little room for the video and the result banner,
which are what the operator actually watches during an event. Moving controls into a
sidebar frees that space.

Read first: the picked variant's screenshot for the target shape — regenerate it yourself
if useful (`git show cap/ui-prototype:app/_ui_prototype.py` still exists on that branch in
this repo, kept specifically so you can look at how it built the sidebar variant; it's
reference only, don't just copy it wholesale since it stubbed everything and this task
touches the real `App`). The sidebar groups, top to bottom: title/subtitle (unchanged),
"Cámara" group (Fuente de video / Resolución / Girar / Zoom / Reconectar / Teléfono USB +
phone-status label), then "Registrar" group (Buscar por nombre / DNI a mano / Registrar
button + the F1/F2 hint line). Below that, a hint line about the video staying free of
controls is optional — use your judgment on whether it adds value in the real app or is
prototype filler.

Constraints:

- This changes only layout/grouping/widget parenting, not behavior: every existing
  command, binding (F1/F2/F5/F6/Esc), and widget attribute name that other code reads
  (`self.cb_buscar`, `self.cb_telefono`, `self.lbl_telefonos`, `self.video`, `self.banner`,
  `self.lbl_tipo/nombre/detalle/forzado`, `self.tabla`, `self.lbl_diag`, `self.lbl_camara`,
  `self.lbl_excel`, etc. — check the full current attribute list, don't assume this list is
  complete) must keep working exactly as before. Grep for every `self.<name>` set in
  `__init__` and confirm each is still referenced correctly after the move.
- Keep the bottom status bar (`estado` frame: `self.lbl_camara`, `self.lbl_excel`, close
  button) where it is — it wasn't part of what moved.
- Keep Spanish copy exactly as it exists today unless a label genuinely no longer makes
  sense in the new grouping (e.g. a label that said "Cámara:" inline in a flat row might
  become a group title instead) — minimize copy changes, this is a layout task.
- Don't change `COLORES`, fonts, or the video/banner/table rendering logic.
- Window sizing: the current window likely has an implicit width from packing everything
  horizontally; check whether a fixed/minimum window size is set anywhere (`self.geometry`,
  `minsize`) and adjust if the new layout needs it, but don't make the window awkwardly
  wide or narrow — verify by actually running it (`xvfb-run` + a screenshot, same mechanism
  the prototype used) before calling this done.

Evidence:

- `uv run pytest` and `uv run ruff check .` both pass.
- A real screenshot of the new window (same `xvfb-run` + `import` mechanism as the
  prototype, or Tk's own render) proving the sidebar layout actually renders correctly
  with real widget wiring — not just that it imports without error. Save it somewhere in
  your worktree and report the path; don't claim "looks right" without one.
- Confirm by grep that every `self.<widget>` attribute referenced elsewhere in `app/ui.py`
  (search handlers, `_vigilar_telefonos`, etc.) still resolves — no `AttributeError` at
  runtime is the actual bar, not just at import time.

Leave the change uncommitted as usual.
