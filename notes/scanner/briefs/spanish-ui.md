Outcome: every piece of text the event operator actually sees in the check-in
app is native, plain Spanish, with no em dash anywhere in it. Nothing else
about the app's behavior changes.

Read AGENTS.md's "Write plainly" section first: short sentences, one idea
each, name the subject, cut filler, no em dash (split the sentence instead).
Apply that standard to Spanish UI copy the way it's already applied to code
comments and commit messages in this repository — write it the way a Peruvian
event staff member would actually say it, not a textbook or machine-translated
version.

Constraints:
- In scope: `frontend/index.html`, `frontend/src/main.js` (all static text,
  template-literal text, labels, hints, button text, the placeholder
  attribute, and every `showToast(...)` message), plus any other file under
  `frontend/` with user-visible copy.
- The toasts at main.js:87, 101, and 148 currently interpolate the raw Go
  error (`Import failed: ${err}`, `Scan failed: ${err}`, `Could not save
  check-in: ${err}`) straight into the UI. Go's internal error strings
  (`internal/store`, `internal/csvimport`, `internal/sunat`, `app.go`) are
  plumbing for developers, not copy for an operator — do not translate those
  Go strings. Instead, replace each of those three toasts with a short,
  plain Spanish message describing what failed for a non-technical reader
  (list import failed, scan failed, could not save the check-in), and log
  the original `err` to the browser console (`console.error`) so the detail
  isn't lost for debugging.
- Do not touch `app.go` or anything under `internal/` — those errors stay as
  they are; this task is the frontend text layer only.
- Do not change any element `id`, CSS class name, or DOM structure — only
  the text nodes, attribute values, and template-literal copy. `style.css`
  should need no changes unless Spanish text visibly overflows or wraps
  somewhere English didn't; fix layout only if you actually see that happen.
- No new dependencies.

Evidence:
- `go build ./...`, `go vet`, `go test ./...` still pass unchanged (this
  task shouldn't touch Go code, so this just confirms nothing leaked).
- Run `wails dev` (or the Playwright setup the previous task already proved
  works against `naval.csv`), drive the same three flows the earlier task
  verified (listed-guest scan, unlisted-guest scan with SUNAT reachable,
  unlisted-guest scan with SUNAT unreachable), and confirm in your report
  every string visible in each flow is Spanish, plain, and free of "—".
- Trigger at least one of the three error toasts for real (e.g. scan before
  importing a guest list, or force a save failure) and confirm the shown
  message is the new plain Spanish text, not the raw Go error, while the
  raw error still appears in the browser console.
