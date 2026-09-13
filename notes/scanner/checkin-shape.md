# Event check-in/out desktop app — shaping note

## 0. Does this fire

Yes. Most of the mechanism is already decided (Wails, SQLite, HID-wedge scanner
input, toggle-based entrada/salida), but one real fork remains open: how the app
scopes data to "an event." Getting that wrong is expensive to unwind once the
SQLite file has real attendance rows in it from the actual event.

## 1. Requirements

- **R1** (known) — The app reads a barcode scan (HID keyboard-wedge digits +
  Enter) with no special driver or SDK, as long as the app window has focus.
- **R2** (known) — On scan, the app resolves the DNI to a full name from the
  locally imported guest list before ever calling the network.
- **R3** (known) — If the DNI is not in the local list, the app tries the SUNAT
  lookup endpoint and falls back to manual name entry on failure or timeout,
  without blocking the check-in flow either way.
- **R4** (known) — Staff can reject a proposed name and enter the correct name
  by hand, for both listed guests and walk-ins.
- **R5** (known) — Each confirmed scan logs `entrada` or `salida`, chosen as
  the opposite of that guest's most recent logged direction for the event
  (no prior row = `entrada`).
- **R6** (known) — The guest list CSV is imported at runtime, not baked into
  the binary at build time, so the same installed app can be reused for a
  future event with a different list.
- **R7** (spike, resolved) — The app runs as a native Windows binary on the
  event laptop with no required internet connection and no separate runtime
  install step for staff to perform.
- **R8** (known) — Rapid duplicate scans of the same DNI within a short window
  (~3s) don't create two flipped log rows from one physical scan.
- **R9** (known) — Attendance data (guest list + log) persists in a local file
  the organizer can pull after the event for headcount/audit.
- **R10** (known) — Ships in time for this specific event without spending
  build or test time on surface area this event doesn't need.

## 2. Spikes

- **R7 — Windows deployment without an internet dependency.** Resolved via
  Context7 (`/websites/wails_io`, wails.io/docs/guides/windows): Wails apps
  need the Microsoft WebView2 Runtime, controlled by the `-webview2` build
  flag with four strategies (Download / Embed / Browser / Error). Building
  with `wails build -nsis -webview2 embed` bundles the WebView2 installer
  into the generated NSIS installer, so the laptop needs neither internet nor
  a pre-existing WebView2 install at setup time. `wails build -nsis` alone
  produces the one-click installer; `Info` fields in `wails.json` cover the
  installer metadata (company/product name, version).

No other spike was needed — CSV shape, SUNAT fallback, toggle logic, and
debounce window are all decisions makeable from what's already been stated,
not facts to go discover.

## 3. Shapes

Only the event-scoping mechanism genuinely forks; the scan/lookup/toggle
mechanics (R1–R5, R7, R8) are identical across all of them.

- **A — No event concept.** One guest table, one log table, no `event_id`
  anywhere. "Import CSV" on first run populates the one guest list that
  exists. Simplest schema and UI.
- **B — `event_id` column, no switcher UI.** Add a single `event_id` text
  column to both tables now; import and log queries are scoped by it. No
  in-app event picker for v1 — reusing the app for a second event means
  pointing it at a fresh SQLite data file (one operator step), which a future
  version could turn into a picker without a schema change.
- **C — Full multi-event UI.** Event switcher screen, "create event" flow,
  per-event CSV import, all visible in app chrome. Most reusable, most
  surface area to build and test before this event ships.
- **D — CSV embedded at build time** (the boring baseline / why-not). Bake
  `naval.csv` into the binary. Rejected already — directly contradicts R6,
  included here only as the "do nothing" comparison point.

## 4. The cross

| | A | B | C | D |
|---|---|---|---|---|
| R6 — reusable for a future event without a rebuild | ✗ manual DB surgery to reuse | ✓ swap data file, add a picker later with no schema change | ✓ | ✗ contradicts R6 by construction |
| R9 — auditable local data file | ✓ | ✓ | ✓ | ✓ |
| R10 — ships in time, minimal surface for this event | ✓ | ✓ | ✗ switcher + create-event flow need building and testing before the event | ✓ (but fails R6) |

**Pick: B.** R6 is the requirement that decides it — the app should outlive
this one event without a rebuild, and a single `event_id` column costs one
extra `WHERE` clause today. R10 stays satisfied because B adds no UI beyond
what this event needs. What B gives up: there's no built-in "pick an event"
screen, so running the app against a second event means starting from a new
data directory — an acceptable one-line operator step for a single-laptop,
single-operator tool, and cheap to upgrade into a real picker later since the
schema already carries `event_id`.

## Decided (not shaped — already fixed this session)

- Stack: Wails (Go) + `modernc.org/sqlite` (pure Go, no CGO/compiler needed on
  the laptop) + `encoding/csv` for import. Compared against Deno+webview and
  rejected the latter for packaging/installer immaturity on a one-shot event
  tool.
- Lookup order: local guest table first, SUNAT only as a best-effort fallback
  for walk-ins, manual entry as the terminal fallback — never blocks logging.
- Direction logic: toggle off the guest's last log row for the event, not a
  fixed direction per scan.
