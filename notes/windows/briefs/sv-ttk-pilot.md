Outcome: `app/ui.py`'s window uses the `sv_ttk` theme (light mode) instead of the bare
platform-default ttk theme, and the frozen PyInstaller build actually bundles the theme's
Tcl/asset files so it still works in the shipped .exe, not just from source.

Context: `notes/windows/ttk-polish-scout.md` (read it in full) investigated why the UI
looks unpolished, found the real cause (no `ttk.Style().theme_use(...)` call anywhere —
`app/ui.py:136` creates a `ttk.Style(self)` but only touches Treeview fonts/rowheight),
and picked `sv_ttk` (MIT, https://github.com/rdbende/Sun-Valley-ttk-theme) as the pilot:
one `pip`/`uv` dependency, one `sv_ttk.set_theme("light")` call before widgets are built,
and it also repaints classic `tk.Frame`/`tk.Label` widgets this app still mixes in (see
`app/ui.py`'s video-frame help label and banner labels, which are `tk.Label` not
`ttk.Label`), so it should look coherent even without converting every widget to ttk.

Steps:

- Add `sv_ttk` as a project dependency (`uv add sv_ttk` or the pyproject equivalent).
- Call `sv_ttk.set_theme("light")` early in `App.__init__` (after `super().__init__()`,
  before the sidebar/body widgets are built) — check the package's own README for the
  exact recommended call site and ordering, don't guess.
- PyInstaller: the scout flagged that `sv_ttk` ships its `.tcl`/asset files as package
  data with no PyInstaller hook, so `AsistenciaDNI.spec` needs an explicit data-collection
  entry (e.g. `collect_data_files("sv_ttk")`, see PyInstaller's runtime-information docs)
  or the frozen .exe will fail to find the theme at runtime. Add that to the spec.
- Verify the app still renders correctly from source: same `xvfb-run` + screenshot
  mechanism used by the earlier `ui-prototype`/`ui-sidebar-layout` tasks — capture a
  screenshot of the real running `App` (not a stub) with the theme applied and compare it
  to before. Report the screenshot path.
- You cannot build/run the actual Windows .exe in this environment — say so plainly rather
  than claiming the frozen build works. Instead: verify by reading `AsistenciaDNI.spec`
  and `sv_ttk`'s own packaging notes that the data-collection entry you added is the
  correct, documented way to ship its assets in a frozen build, and note this needs a real
  Windows release-workflow run to fully confirm (the captain will trigger one).

Constraints:

- Don't touch `app/ui.py`'s widget structure/layout (the sidebar layout that just landed)
  — only add the theme call. If the theme visibly clashes with any of this app's explicit
  hardcoded colors (`COLORES` dict, banner background colors, the black video frame), note
  it in your report rather than silently tweaking colors — that's a judgment call for the
  captain, not something to fix without being asked.
- `uv run pytest` and `uv run ruff check .` must still pass.

Evidence: before/after screenshots (reuse the earlier prototype's rendering approach), the
diff, and an explicit note on what frozen-build verification you could and could not do
locally.

Leave changes uncommitted as usual.
