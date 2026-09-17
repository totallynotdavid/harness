Outcome: `app/ui.py`'s real `App` window is rebuilt to match the picked "refined" prototype
(GitButler-inspired, light theme, bordered surfaces), minus its icon rail — the captain
picked this direction after reviewing four real screenshots. Build it directly in
`app/ui.py`, not as another prototype.

Reference (read this first, it's on a still-existing branch in this repo): `git show
cap/ui-setup-operate-prototype:app/_ui_setup_operate_prototype.py` for the exact
implementation the captain reviewed, and its two screenshots for the target shape — main
view and the settings dialog. This is reference only: it stubbed all I/O and hardcoded fake
data, and this task touches the real `App` with real wiring.

Picked shape, main view (top to bottom / left to right):
- Compact header: app title + "CICAT" subtitle on the left; camera/phone connection status
  (read-only text, e.g. "Pixel 8 · USB · listo") plus F1/F2/Esc hint on the right.
- NO icon rail. The prototype's left-side icon column (4 unlabeled icons) does not map to
  anything this single-screen app has — drop it entirely. Do not replace it with anything;
  the video panel starts where the rail used to be.
- Video feed in a bordered card, same content/behavior as today (help text when
  disconnected, live preview when connected).
- Right column: a bordered "última lectura" result panel (accent-bar + state text, replacing
  today's full-width colored banner — check the prototype's exact treatment), then "Últimas
  lecturas" table, then a "Registro manual" section at the bottom with the name-search
  combobox and a compact DNI-entry control (see prototype's "Busque por nombre o use el
  DNI" combined framing — decide whether to keep the fields visually merged like the
  prototype or keep them as two labeled fields; use your judgment, the prototype was a
  rough pass on this specific area).
- A "Configuración" button opens a dialog (Toplevel) containing exactly what's in the
  prototype's settings screenshot: Cámara group (Fuente de video, Resolución, Girar, Zoom,
  Reconectar), Teléfono USB group, and the F5/F6 hint line, with a Cerrar button.

Constraints (same as the earlier `ui-sidebar-layout` task, still apply):
- Every existing command, binding (F1/F2/F5/F6/Esc), and widget attribute name other code
  reads (`self.cb_buscar`, `self.cb_telefono`, `self.lbl_telefonos`, `self.video`,
  `self.banner` or its replacement, `self.lbl_tipo/nombre/detalle/forzado`, `self.tabla`,
  `self.lbl_diag`, `self.lbl_camara`, `self.lbl_excel`, etc.) must keep working. Grep the
  full current attribute list before starting and confirm each is still wired correctly
  after the rebuild — no `AttributeError` at runtime is the actual bar, not just at import
  time.
- Keep the `sv_ttk` theme (already merged) — this rebuild works with it, not against it;
  if the prototype's light/bordered look needs style tweaks beyond what sv_ttk gives by
  default, use `ttk.Style().configure(...)` calls, not a second theme library.
- Keep Spanish copy, matching existing tone; minimize copy changes outside what the new
  structure requires.
- Don't change `COLORES`, pipeline/business logic, or camera/Excel/SUNAT wiring — this is a
  presentation-layer rebuild.
- The settings dialog is a `Toplevel`: make sure closing it (window X, or its own Cerrar)
  doesn't break anything that depends on those widgets existing continuously (e.g. if
  `_vigilar_telefonos` or similar periodic updates touch `self.cb_telefono`/
  `self.lbl_telefonos`, decide whether those widgets need to exist even when the dialog is
  closed, or whether the periodic updater needs a null-check/guard — verify this concretely
  by testing open/close/reopen, don't assume it's fine).

Evidence:
- `uv run pytest` and `uv run ruff check .` both pass.
- A real screenshot of the new window (same `xvfb-run` + `import` mechanism as before)
  showing the main view, AND one showing the settings dialog open, proving both render
  correctly with real widget wiring, not stub data.
- Confirm by grep that every `self.<widget>` attribute referenced elsewhere in `app/ui.py`
  still resolves.
- A quick manual note on how you handled the settings-dialog-closed case for anything that
  updates those widgets periodically.

Leave the change uncommitted as usual.
