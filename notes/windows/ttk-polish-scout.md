# ttk / Tkinter polish scout

As-of date: 2026-09-16. Scope: read-only inspection of the Windows app and GitHub repositories; application source was left unchanged.

## Direct verdict

No: the “unpolished, internals showing” look is not an innate limitation of Tkinter. It is primarily a missing theme/style decision in this app, and the first experiment really is a small change: load a deliberate ttk theme immediately after creating the root and before building the widgets.

Python’s own documentation describes `ttk` as the themed widget set that adapts to the platform’s native theme and gives a more consistent look than classic Tk widgets. The app creates `ttk.Style(self)` but only changes Treeview row height and fonts; it never calls `theme_use`, so it gets whatever Tk’s platform default happens to be. See [`app/ui.py`](/home/dubu/.cap-work/ttk-polish-scout/app/ui.py:136).

That small change will improve the client-area controls, but it is not a complete visual redesign. This app also mixes ttk widgets with classic `tk.Frame`/`tk.Label` widgets and explicit colors, and ttk themes do not automatically redesign the Windows titlebar. Those are separate polish layers.

## What mature Tkinter software actually does

The clearest downstream example found was [System Monitoring Center](https://github.com/hakandundar34coding/system-monitoring-center), a substantial Tkinter desktop application (984 stars; last pushed 2026-05-25). Its [MainWindow.py](https://github.com/hakandundar34coding/system-monitoring-center/blob/main/src/MainWindow.py) imports and vendors `sv_ttk`, explicitly selects light/dark themes with `sv_ttk.set_theme(...)`, sets fonts, and uses an application icon via `iconphoto`. Its README identifies Tkinter and sv_ttk and shows the light/dark product UI. This is evidence of theme selection being part of a real application’s visual system, not evidence that Tkinter must be abandoned.

[Pygubu Designer](https://github.com/alejandroautalan/pygubu-designer) is another mature Tkinter application (1,067 stars; last pushed 2026-09-13). Its [theming service](https://github.com/alejandroautalan/pygubu-designer/blob/master/src/pygubudesigner/services/theming.py) has adapters for sv_ttk, ttkbootstrap, and ttkthemes and centralizes theme switching. The production pattern is: choose a theme deliberately, centralize style setup, own the fonts/icons/resources, and handle Windows integration separately.

## Candidate audit

GitHub “dependents” below are the visible network/dependents counts checked on 2026-09-16. They are useful adoption evidence but undercount PyPI or private usage.

| Package/repository | GitHub evidence | License | Dependents | Windows/PyInstaller fit and cost | Maintenance risk |
|---|---|---|---:|---|---|
| [Sun Valley ttk theme](https://github.com/rdbende/Sun-Valley-ttk-theme) (`sv_ttk`) | 2,583 stars, 127 forks; latest commit [`16a9ccc`](https://github.com/rdbende/Sun-Valley-ttk-theme/commit/16a9ccca67d9e64f8b77bf189e854c2131073dae), 2025-06-08; 31 open issues | MIT | 0 repos / 0 packages | Best fit for a small visual pilot. It is a normal Python package with `sv.tcl` and theme assets in [setup.py](https://github.com/rdbende/Sun-Valley-ttk-theme/blob/main/setup.py). Add the package and one `sv_ttk.set_theme("light")` call. Because it has no PyInstaller hook, explicitly collect its package data in the spec with `collect_data_files("sv_ttk")` (or equivalent). | Medium: visually focused and MIT, but its last code commit is over a year old and it has an open issue backlog. |
| [ttkbootstrap](https://github.com/israel-dryer/ttkbootstrap) | 2,650 stars, 458 forks; latest commit [`37d7b35`](https://github.com/israel-dryer/ttkbootstrap/commit/37d7b3584b8f3b70671b30f798b0e30378ae1190), 2026-09-12; 1 open issue; 3,936 repos / 146 packages dependents | GitHub identifies MIT; its [package metadata](https://github.com/israel-dryer/ttkbootstrap/blob/master/pyproject.toml) declares `MIT AND (Apache-2.0 OR BSD-2-Clause)`, so review the bundled asset licensing before shipping | 3,936 / 146 | Strongest packaging story: installed ttkbootstrap registers a PyInstaller hook that collects its assets, and its packaging guide says no extra spec data is needed when installed. It requires Pillow and includes image assets. This app’s spec deliberately excludes `PIL`, so integration requires removing/adjusting that exclusion and testing the frozen exe. Broad adoption is more than one line because the package’s recommended `App`/`Window` and bootstyle APIs may require root/widget changes. | Low-to-medium: very active and widely adopted, but larger integration surface, Pillow/freeze interaction, and the mixed metadata license need review. |
| [Azure ttk theme](https://github.com/rdbende/Azure-ttk-theme) | 848 stars, 143 forks; latest commit [`997dbbe`](https://github.com/rdbende/Azure-ttk-theme/commit/997dbbef09563c3a0b2541ae3de5cd774f1640fb), 2023-10-30; 10 open issues | MIT | 0 / 0 | Direct Fluent-like visual option, but it is source/Tcl-oriented rather than a maintained Python package. Bundle `azure.tcl`, its theme Tcl files, and PNG assets explicitly; then source the theme and call `theme_use`. More packaging and path maintenance than sv_ttk. | High: no code commit since 2023, last release in 2022, and no visible dependents. |
| [Forest ttk theme](https://github.com/rdbende/Forest-ttk-theme) | 464 stars, 96 forks; latest code commit [`4fdde95`](https://github.com/rdbende/Forest-ttk-theme/commit/4fdde9530267ffd42443622ce55c5aea2d8c8188), 2021-07-28; 11 open issues | MIT | 0 / 0 | Similar Tcl-plus-image bundling burden to Azure; not a good Windows shipping default for this project. | High: effectively stale for a product dependency. |
| [TKinterModernThemes](https://github.com/RobertJN64/TKinterModernThemes) | 181 stars, 11 forks; latest commit [`a7a687b`](https://github.com/RobertJN64/TKinterModernThemes/commit/a7a687b971ed6d1b225883239a8bcddbdd65576b), 2025-10-09; 0 open issues | MIT | 0 / 0 | It packages Park/Sun-Valley/Azure theme files, but its main abstraction is `ThemedTKinterFrame`, which creates/configures the root and owns layout behavior. Good for a new app; adapting this existing `App(tk.Tk)` is a wrapper/layout migration, not a five-minute fix. | Medium: active enough, but small adoption footprint and strong architecture coupling. |

One tempting alternative was [ttkthemes](https://github.com/TkinterEP/ttkthemes): 412 stars, 55 forks, latest commit 2025-11-09, 6 open issues, and 2,996 repos / 79 packages dependents. It was not treated as an acceptable candidate because GitHub reports GPL-3.0 for the package, while its README says the core is GPLv3 and only some themes have BSD-like terms. That license result is a shipping constraint, not a technical failure to solve casually.

## Ranked fixes

### 1. Pilot `sv_ttk` first

This has the best ratio of Windows-appropriate appearance to change size. Its README provides the simple `pip install sv-ttk`, import, and `set_theme("light")` flow. Its Tcl file also updates the palette used by classic Tk controls, which gives this mixed ttk/classic-Tk UI a better chance of looking coherent than a ttk-only styling call. Explicit app colors such as `#F3F3F3`, black video background, and the banner colors will still need intentional review.

Expected change: one dependency, one import, one theme-selection call before `_construir`, and one PyInstaller data-collection entry. The relevant PyInstaller mechanism is documented in [PyInstaller’s runtime-information guide](https://pyinstaller.org/en/stable/runtime-information.html). Do not assume the Tcl files are included merely because the Python package imports: verify the frozen exe and confirm that `sv_ttk/sv.tcl` and its theme assets exist in the bundle.

The [sv_ttk implementation](https://github.com/rdbende/Sun-Valley-ttk-theme/blob/main/sv_ttk/__init__.py) loads package-relative Tcl resources, so the frozen-resource test is the main technical risk. Its README also plainly says it does not change the Windows titlebar; titlebar dark mode would be a separate optional Windows integration.

### 2. Evaluate `ttkbootstrap` if the pilot needs a longer-lived, broader styling system

This is the strongest maintenance/adoption choice: it was updated days before this report, has only one open issue, and has far more visible dependents than the other MIT candidates. Its [PyInstaller hook](https://github.com/israel-dryer/ttkbootstrap/blob/master/src/ttkbootstrap/_pyinstaller/hook-ttkbootstrap.py) and [packaging guide](https://github.com/israel-dryer/ttkbootstrap/blob/master/docs/user-guide/how-to/packaging.rst) are unusually relevant to this frozen-exe project.

It is not the lowest-risk first change here. ttkbootstrap depends on Pillow, while [`AsistenciaDNI.spec`](/home/dubu/.cap-work/ttk-polish-scout/AsistenciaDNI.spec:1) explicitly excludes `PIL`; that conflict must be resolved and a clean frozen build tested. Adopting its richer bootstyle API may also touch many widget declarations. Confirm the package’s mixed license expression for all shipped assets.

### 3. Keep Azure as a visual fallback, not the default recommendation

Azure is MIT and may be the closest visual match if the desired result is a Fluent-style control set. However, its source-oriented Tcl/PNG layout, lack of package/dependent signals, and 2023 last commit make it a higher-maintenance choice than the first two. It should only be selected after a screenshot comparison demonstrates a material advantage over sv_ttk.

## Other “Tk internals showing” symptoms checked

### Icon quality

This is already in reasonably good shape and is not the root cause. [`recursos/icono.ico`](/home/dubu/.cap-work/ttk-polish-scout/recursos/icono.ico) contains seven sizes: 16, 24, 32, 48, 64, 128, and 256 px. The app uses Windows `iconbitmap(default=...)`, and the PyInstaller spec supplies the same ICO as the executable icon. Python’s Tk documentation describes `iconbitmap(default=...)` for Windows and also documents `iconphoto` with multiple differently sized images. A better icon is therefore not the first fix; only test whether every secondary window/taskbar surface selects the intended image.

### Fonts

The app is Windows-only and intentionally uses Segoe UI for most controls, plus Consolas for diagnostics, so there is no obvious generic-font leak. It does hardcode those families in many widget declarations, however. [Thonny’s workbench](https://github.com/thonny/thonny/blob/master/thonny/workbench.py), a mature MIT Tkinter application, checks available font families and configures named fonts for the editor, I/O, menus, and dialogs. If screenshots still differ across Windows installations, the production pattern is to centralize named fonts and provide fallback selection; this is a secondary cleanup after testing the theme.

### Titlebar and non-client chrome

Tk does not draw the normal Windows titlebar: the window manager does. The Python Tk documentation explicitly assigns titlebar, border, controls, title, position, size, and icon responsibilities to the window manager. A ttk theme therefore cannot make the titlebar match the client area. sv_ttk’s README confirms this limitation and points to an optional Windows titlebar-styling package. Treat a custom/non-native titlebar as a separate, higher-risk product decision; it is not required to validate whether theming fixes the complaint.

### Taskbar grouping and identity

The current code has a single-instance mutex and looks up the window by title, but it does not set an explicit Windows AppUserModelID. Microsoft documents that an explicit AppUserModelID guarantees how windows, processes, and shortcuts are associated with a taskbar button; without one, Windows uses heuristics. For this one-process/one-window app, this is not evidence of the current unpolished look. If the observed bug is a generic taskbar icon or bad grouping, add an explicit ID before creating the Tk root and use the same ID in the shortcut. See Microsoft’s [AppUserModelID documentation](https://learn.microsoft.com/en-us/windows/win32/shell/appids).

### High-DPI behavior

The existing call is not “wrong” in the sense of being ineffective, but `SetProcessDpiAwareness(1)` means `PROCESS_SYSTEM_DPI_AWARE`, not per-monitor aware. Microsoft defines level 2 as `PROCESS_PER_MONITOR_DPI_AWARE`; the newer `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` adds per-monitor-v2 behavior, including non-client/menu/common-control handling. Microsoft recommends declaring the default in the application manifest and making any API call before creating windows; see [process DPI awareness](https://learn.microsoft.com/en-us/windows/win32/api/shellscalingapi/ne-shellscalingapi-process_dpi_awareness), [SetProcessDpiAwareness](https://learn.microsoft.com/en-us/windows/win32/api/shellscalingapi/nf-shellscalingapi-setprocessdpiawareness), and [DPI awareness contexts](https://learn.microsoft.com/en-us/windows/win32/hidpi/dpi-awareness-context).

The mature Tk application checked, [Thonny’s main.py](https://github.com/thonny/thonny/blob/master/thonny/main.py), also uses system-DPI awareness level 1. A stronger PMv2 call is therefore not an evidence-backed one-line Tk fix for this app. It is worth a separate two-monitor acceptance test: system-aware processes can be scaled/blurred when moved between monitors with different scale factors. If that test fails, investigate a manifest/PMv2 change with the Tk version and all geometry behavior in scope.

For comparison, [NVDA’s DPI module](https://github.com/nvaccess/nvda/blob/master/source/winAPI/dpiAwareness.py) uses a modern PMv2 context with fallbacks, but NVDA is a native Windows application rather than a Tkinter reference. Its pattern supports the Windows claim that PMv2 is a stronger platform integration option; it does not establish that changing this Tk app’s call is safe without testing.

## Recommendation

Try `sv_ttk` in a branch/pilot first, capture the normal and frozen-exe screenshots, and check the video/banner, Treeview, combobox, focus states, secondary windows, and titlebar as separate surfaces. Keep the existing multi-size icon. If the visual complaint remains after the theme, then decide whether the remaining issue is explicit classic-Tk colors, centralized fonts, or Windows chrome.

If the pilot exposes resource or maintenance concerns, use the same screenshot as a baseline for ttkbootstrap. Choose ttkbootstrap for the longer-term styling investment only after resolving the Pillow exclusion and license/package-data review. Do not spend the first iteration on a custom titlebar, AppUserModelID, or PMv2: those are real platform concerns, but the evidence points to the absent ttk theme as the missing five-minute improvement.

## Files and failure status

No application files were changed. No tool installation was needed (`gh` was available and authenticated), and no implementation/test failure occurred because this was explicitly a report-only scout. The rejected alternatives and their concrete failure signals are recorded above: Azure/Forest are stale, TKinterModernThemes is architecturally coupled to a root wrapper, ttkbootstrap conflicts with the current frozen-build `PIL` exclusion until tested, and ttkthemes has a GPL-3.0 package license.
