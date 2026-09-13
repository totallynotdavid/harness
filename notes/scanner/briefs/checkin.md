Outcome: A Wails (Go) desktop app in this repo that lets one operator scan a DNI
barcode (a USB scanner acting as a HID keyboard wedge — it types the DNI digits
then Enter into whatever has focus, no driver/SDK involved), get an instant
name lookup with a confirm/reject/manual-entry step, and log entrada/salida per
guest per event to a local SQLite file. It must run at a live event with no
internet connection required after the app is installed.

Read notes/scanner/checkin-shape.md first (in the captain repo, one level above
this worktree's origin) for the reasoning behind these decisions. This repo has
no AGENTS.md yet — you are establishing the project from an empty slate except
for naval.csv, so make the structure you'd want a second task to find later
(one clear entrypoint, one clear place SQLite/CSV logic lives), but don't
over-build: this is a single-laptop, single-operator tool, not a service.

Constraints:
- Stack: Go + Wails v2, `modernc.org/sqlite` (pure Go, no CGO) for storage,
  stdlib `encoding/csv` for import. No other new dependencies without
  reporting first and waiting — this is the only task on this project, so
  there's no one to collide with, but the manifest is still the contract for
  whatever comes next.
- Schema: both the guest table and the attendance log carry an `event_id`
  column, even though v1 ships no event-switcher UI. One event's data per
  running data directory is enough for v1; do not build an event picker.
- Guest list import happens at runtime (an explicit "Import guest list" action
  pointed at a CSV path), never embedded into the binary at build time. The
  CSV columns are `ITEM, APELLIDOS Y NOMBRES, DNI` with a UTF-8 BOM (see
  naval.csv in this repo) — import against the real file, but the import code
  must work for any CSV with those three columns, not just this one.
- Lookup order on scan: local guest table first — a listed guest's name must
  come back with zero network calls. Only a DNI absent from the local list
  goes to the SUNAT endpoint:
  `https://ww1.sunat.gob.pe/ol-ti-itfisdenreg/itfisdenreg.htm?accion=obtenerDatosDni&numDocumento=${dni}`
  with a short timeout (a few seconds) and a hard fallback to manual entry on
  any failure — timeout, non-200, unexpected response shape, DNS failure,
  whatever. A blocked or unreachable SUNAT endpoint must never stop a walk-in
  from being logged; it just means they get the manual-entry form instead of
  a prefilled name.
- Direction is a toggle off the guest's own last attendance_log row for this
  event: no prior row, or the last row was salida → entrada; last row was
  entrada → salida. Never ask the operator to pick a direction by hand.
- Debounce identical DNI scans within roughly 3 seconds, so one physical scan
  (scanners can double-fire Enter) doesn't create two flipped log rows. A
  deliberate re-scan after that window is a normal toggle, not an error.
- Confirm UI: an always-focused input captures the scanner's digits-then-Enter
  stream; on Enter, show the looked-up (or SUNAT-fetched) name with
  Confirm/Reject; Reject opens a manual name-entry form that still logs
  against the scanned DNI. Keep this to one screen — no multi-step wizard.

Windows packaging (read before you assume you can verify this locally): this
dev environment is Linux. Wails' own cross-platform guidance builds each OS
target on that OS (its GitHub Actions example uses a `windows-latest` runner
for the `windows/amd64` build) — there is no documented reliable path to
produce a real `windows/amd64` WebView2-embedded build by cross-compiling from
Linux. Do not attempt to fake this or claim it works untested. Instead:
- Get the application logic, SQLite layer, CSV import, and lookup/toggle/
  debounce behavior fully working and tested on the linux/amd64 target you can
  actually run here (`wails build` / `wails dev` on Linux, with
  `-tags webkit2_41` if this distro lacks webkit2gtk-4.0).
- Write (but do not need to run) a `wails build -nsis -webview2 embed`
  invocation and document, in your final report, exactly what still has to
  happen on a real Windows machine before the event: install Go + Wails CLI +
  NSIS there, run that build command, confirm the installer runs without
  requiring a pre-existing WebView2 install. Say this plainly as a remaining
  step, not something you did.

Evidence:
- `go build ./...` and `wails build` (linux/amd64) succeed.
- A test (scripted where practical, otherwise a documented manual run against
  `wails dev`) imports naval.csv, then simulates a typed-then-Enter DNI
  input for: a DNI present in naval.csv (name appears, provably with no
  network call — e.g. by running with network disabled), and a DNI absent
  from it with network reachable (SUNAT-sourced name appears for confirm) and
  with network unreachable (falls straight to manual entry, no hang, no
  crash).
- Two scans of the same DNI within 3 seconds produce exactly one new
  attendance_log row (the second is debounced); two scans 5+ seconds apart
  correctly toggle entrada then salida.
- Confirm in your final report whether `wails build -nsis -webview2 embed`
  is at least accepted by the Wails CLI's flag parsing (even if it can't
  fully execute for a Windows target on this host), and state clearly what
  remains to be done on a Windows machine before the event.
