# windows (Asistencia DNI) — SUNAT, name-search manual entry, UI refresh

## 0. Does this fire

Yes. The captain named three outcomes for a codebase Captain didn't write
(`/home/dubu/git/windows`, teammate-authored, Python/tkinter). Real forks: how
a SUNAT result should be surfaced without contradicting this app's read-only
roster model, what mechanism "search by name" should use, and how many briefs
this becomes. Getting the split wrong means two agents editing the same 60
lines of `app/ui.py` at once.

## 1. Requirements

- **R1** (known) — When a scanned or typed DNI isn't in the roster, the app
  tries SUNAT before falling back to `DESCONOCIDO`, using the same contract
  the old `scanner` project already proved live: GET
  `https://ww1.sunat.gob.pe/ol-ti-itfisdenreg/itfisdenreg.htm?accion=obtenerDatosDni&numDocumento=${dni}`,
  5s timeout, JSON `{lista:[{nombresapellidos}], error}`, name normalized
  from `"APELLIDOS,NOMBRES"` to one string. Any failure (timeout, non-200,
  bad shape, `error` field, empty list) falls back to today's `DESCONOCIDO`
  path — SUNAT never blocks or delays a check-in past its timeout.
- **R2** (known) — A SUNAT-resolved name appears in the attendance log row
  and the on-screen banner/table for that scan, exactly like a roster hit
  (green ENTRADA/SALIDA banner, not the orange "unknown" one), but the
  roster itself (`Roster`, backed by the read-only Personal sheet) is not
  mutated — `reload_personal` stays the only writer to `Roster._personas`.
- **R3** (known) — Staff can register a known participant by searching the
  loaded roster by name (substring, accent/case-insensitive) and picking a
  result, without typing or knowing that person's DNI, for both entrada and
  salida — the picked person's DNI feeds `pipeline.procesar` exactly like a
  scanned one, so debounce/toggle/logging behavior (R5–R8 of the original
  `checkin-shape.md`, still true here) is unchanged.
- **R4** (known) — Name search only searches people already in the roster
  (the closed participant list) — it is not a directory-add flow and never
  creates a new roster entry. A search with no match tells staff to check
  the Personal sheet, the same message DESCONOCIDO already shows.
- **R5** (known) — The DNI-entry bar stays for staff who do have the number
  (e.g. reading it off a printed list) — name search is an addition next to
  it, not a replacement.
- **R6** (known) — After R1–R5 ship, `app/ui.py`'s visual layout (spacing,
  grouping of the camera/manual/search controls, banner, table) gets a
  cleanup pass so the new controls don't look bolted on — same widgets and
  event flow, no behavior change.
- **R7** (known) — No new UI text is introduced in English; this app's
  existing Spanish copy style (see README, existing banner strings) is the
  bar for any new label/placeholder/error text.

## 2. Spikes

- **SUNAT response contract.** Resolved by reading `scanner`'s already-live,
  tested implementation (`/home/dubu/git/scanner/internal/sunat/sunat.go`,
  `sunat_test.go`) instead of re-discovering it: same URL, same JSON shape,
  same failure handling. Porting the *contract*, not the Go code — Python
  gets its own `urllib`/`requests`-based client matching this repo's
  existing style (no `requests` dependency currently in the codebase; check
  `requirements*.txt` before adding one — stdlib `urllib.request` may be
  preferred to avoid a new dependency the brief should decide, not guess).
- **Roster mutability.** Resolved by reading `excel_sync.py`: `reload_personal`
  is the only writer to `Roster`, called from a background sync loop —
  confirms R2's "don't mutate the roster" is consistent with existing
  architecture, not a new constraint fighting it.
- **Search mechanism cost.** Not spiked further — roster size is one event's
  participant list (the existing `naval.csv`-scale data the old project
  worked from), so an in-memory linear filter over `Roster`'s existing dict
  is sufficient; no index structure is a real question worth a spike.

## 3. Shapes

### Fork A — brief split

- **A1 — One brief for R1–R5 (SUNAT + name search), a second for R6+R7 (UI
  cleanup), run in sequence.** The second brief starts only after the first
  lands, so the cleanup pass covers the real, final set of controls instead
  of guessing where a not-yet-built search box will go.
- **A2 — One brief for everything.** Single agent designs the new controls
  and polishes the whole toolbar in one pass.
- **A3 — Three parallel briefs** (SUNAT, name-search, UI cleanup) with
  ownership grants scoped to non-overlapping functions.

### Fork B — name-search UI mechanism

- **B1 — Inline filter combobox.** A `ttk.Combobox` (or `Entry` +
  `Listbox` popup) next to the existing DNI entry: staff types a few
  letters, a dropdown narrows to matching roster names, Enter/click on a
  result registers that DNI. Stays in the existing toolbar, one screen, no
  new window.
- **B2 — Separate "Buscar participante" dialog.** A `Toplevel` modal with
  its own search box and result list. More room for a longer name list, but
  a second window to manage and close, and blocks the main window while
  open (a scan can't be processed mid-search).
- **B3 — Always-visible scrollable name list** (no search field) filtered
  live as the operator types anywhere. Discoverable with zero instruction,
  but consumes permanent screen space the video preview / table currently
  use, in a window already at `minsize(1100, 640)`.

## 4. The cross

### Fork A

| | A1 seq | A2 one brief | A3 parallel |
|---|---|---|---|
| Avoids two agents editing the same `_construir`/toolbar region at once | ✓ | ✓ (one agent) | ✗ same 60-line region, real collision risk |
| Cleanup pass covers the real final controls, not a guess | ✓ | ✓ | ✗ cleanup brief would have to guess where search/SUNAT UI lands |
| Matches "foundations before parallelism" — behavior before appearance | ✓ | ~ (one agent still does both, in whatever order it picks) | ✗ parallelizes before the foundation (the new controls) exists |
| Keeps each brief reviewable and revertible on its own | ✓ | ✗ one large diff mixes behavior and cosmetic changes | ✓ |

**Pick: A1.** Two sequential briefs — first ships R1–R5 (SUNAT lookup +
name-search registration, functionally complete and tested), second does the
R6/R7 visual pass once the real control set exists. This is the same
foundations-before-parallelism call the captain has made standing: get the
mechanism right before styling it, and don't fan work out over a region two
agents would both need to touch. What it gives up: two review rounds instead
of one, and the UI stays visually rough (functional but not cleaned up)
between them — acceptable since brief one ships a working, tested app either
way.

### Fork B

| | B1 inline | B2 dialog | B3 always-visible |
|---|---|---|---|
| One screen, no window management, doesn't block scanning mid-search (R3: works for entrada and salida without extra modal state) | ✓ | ✗ modal blocks the scan loop while open | ✓ |
| Fits the existing `minsize(1100, 640)` toolbar without shrinking the video/table area | ✓ | ✓ (own window) | ✗ needs permanent list space in an already-tight layout |
| Matches the existing interaction pattern (type → Enter → result), so R5's "search sits next to DNI entry" reads as one coherent bar | ✓ | ✗ a whole separate dialog reads as a different feature, not an addition | ~ plausible but changes the toolbar shape more than a combobox does |

**Pick: B1.** An inline filter combobox next to the existing DNI-entry field:
type a few letters of the name, pick from the narrowed dropdown, Enter
registers. It reuses the exact interaction shape staff already has (type,
Enter, see banner), never blocks the scan loop, and fits the current window
without a layout rework — which the brief still gets to do in the R6 pass.
What it gives up against B2: a long roster (many hundreds of names) shows
fewer results at once in a dropdown than a full-height dialog list would,
acceptable for a single-event participant list.

## Decided (not shaped — already fixed this session)

- This repo (`windows`, `https://github.com/cicatnet/windows`) is what ships;
  the earlier Wails rewrite (project `scanner`) is superseded and gets no
  further work from Captain.
- SUNAT lookup order and failure handling: identical decision the old
  `checkin-shape.md` already made — local roster first, SUNAT only as
  fallback, manual path on any SUNAT failure, never a hang.
