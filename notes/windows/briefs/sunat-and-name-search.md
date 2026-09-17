Outcome: two additions to the existing Asistencia DNI app (`/home/dubu/git/windows`,
Python/tkinter, already working — camera scan, local roster lookup, ENTRADA/SALIDA
logging to Excel):

1. When a scanned or manually-typed DNI is not in the local roster (Personal sheet),
   the app tries a SUNAT lookup for the name before falling back to today's
   `DESCONOCIDO` handling, and never blocks or delays a check-in past a short timeout.
2. Staff can register a known participant by searching the already-loaded roster by
   name and picking a result, for people who don't have their DNI on hand — no DNI
   typing required for this path.

Read `/home/dubu/git/captain/notes/windows/checkin-refine-shape.md` first (in the
captain repo, one level above this worktree's origin) for the reasoning behind these
decisions — requirements R1–R5, the SUNAT and search-mechanism forks, and why they're
picked. This is task one of two; a second task will do a purely visual cleanup pass
over `app/ui.py` afterward, so keep new UI additions functional and readable but don't
spend time polishing layout beyond what's needed to make them usable now.

Constraints:

- SUNAT contract (already proven live by another project — port the contract, not any
  code, since that project is Go): GET
  `https://ww1.sunat.gob.pe/ol-ti-itfisdenreg/itfisdenreg.htm?accion=obtenerDatosDni&numDocumento=${dni}`,
  a `User-Agent` header, 5s timeout. Response is JSON:
  `{"lista": [{"nombresapellidos": "APELLIDOS,NOMBRES"}], "error": "...", "message": "..."}`.
  Treat as a miss (fall through to today's `DESCONOCIDO` path) on: any network error,
  timeout, non-200 status, JSON decode failure, non-empty `error`, empty `lista`, or an
  empty `nombresapellidos`. On success, normalize `"APELLIDOS,NOMBRES"` into one
  display name (title-case, single string, not the raw comma form). Use the stdlib
  (`urllib.request`/`json`) rather than adding the `requests` dependency — this repo's
  `requirements.txt` has no HTTP client dependency today and none should be added for
  this.
- Where the lookup slots in: `app/pipeline.py`'s `Pipeline.procesar` currently does
  `persona = self.roster.lookup(dni)` and falls straight to `DESCONOCIDO` on a miss.
  Add the SUNAT attempt between the roster miss and the `DESCONOCIDO` fallback, on a
  background thread (this codebase already runs Excel I/O and camera decode on worker
  threads feeding the `queue.Queue` the tkinter loop polls in `_tick` — follow that same
  pattern rather than blocking the UI thread on the HTTP call). A `Resultado` from a
  SUNAT hit should read as "known" for display (green ENTRADA/SALIDA banner, not the
  orange `desconocido` one) even though `roster.lookup` still returns `None` for that
  DNI — do not conflate "found via SUNAT" with "in the roster" in a way that would make
  a later real roster load treat them as already-known duplicates incorrectly; keep the
  distinction explicit in whatever field/flag you add to `Resultado`.
- Do not write SUNAT results back into `Roster` or into the Personal sheet. `Roster` is
  read-only from the app's own logic today — `ExcelSync.reload_personal` is its only
  writer, driven from the Personal sheet on disk. A SUNAT-resolved name is for that
  attendance log row only, not a roster mutation. The attendance log row itself (the
  Excel `Asistencia` sheet / CSV journal) does get the SUNAT name, same as any other
  logged name.
- Name search: add a filter combobox (or entry + narrowing dropdown, `ttk.Combobox`
  with a dynamically updated `values` list is the simplest fit for this codebase's
  existing `ttk` usage) next to the existing "DNI a mano" entry in the toolbar built in
  `App._construir` (`app/ui.py`). Typing narrows to roster names containing the typed
  text (case- and accent-insensitive substring match — `Roster` only exposes `lookup`,
  so add whatever read method `Roster` needs, e.g. a `search(text) -> list[(dni, nombre,
  area)]`, guarded by the same lock `lookup` already uses). Selecting a result (Enter or
  click) calls `self._procesar(dni, "manual")` exactly like the existing DNI-entry path,
  so it goes through the same debounce/toggle/logging behavior unchanged. A search with
  no matches shows the existing "not found, check the Personal sheet" style message
  rather than inventing new copy. Keep the existing DNI-entry field working unchanged —
  this is an addition, not a replacement.
- Spanish UI copy only, matching this app's existing plain, direct style (see current
  banner strings in `app/ui.py`, e.g. `"NO SE GUARDÓ"`, `"DNI inválido"`) — no
  English strings, no em dash.
- This repo has no `AGENTS.md` yet. Do not add one as part of this task — that's
  a separate concern from shipping these two features; note in your final report if you
  think one is warranted, but don't build it unasked.

Evidence:

- `pytest` (existing suite, `tests/`) still passes unchanged, plus new tests for: the
  SUNAT client's success path, its handling of each failure mode listed above (timeout,
  non-200, malformed JSON, `error` field, empty list — a fake HTTP server or mocked
  transport, not the real endpoint, for these), and `Roster.search` (case/accent
  insensitivity, substring matching, no-match case). Follow `pytest.ini`'s existing
  `-m "not excel"` convention for any test that needs a live Excel process.
- A live run (`wails`-equivalent here is just running the app — document the command
  you used, e.g. `python -m app.main` or however `iniciar.bat`/`lanzador.pyw` launches
  it) driving: a DNI present in the roster (name from roster, no SUNAT call — prove this
  the same way the earlier Go project did, e.g. by running with network disabled or by
  asserting via a log/mock that no HTTP call happened), a DNI absent from the roster
  with network reachable (SUNAT name appears, logged, green banner), a DNI absent with
  network unreachable (falls to today's `DESCONOCIDO` path, no hang, no crash), and the
  name-search path registering a known participant by name only, producing a correct
  ENTRADA then SALIDA on two uses.
- Confirm in your final report that `Roster`/Personal-sheet data is unchanged by a SUNAT
  hit (re-read the sheet or inspect `Roster._personas` size before/after) and that the
  attendance log row for a SUNAT hit carries the SUNAT name, not `DESCONOCIDO`.
