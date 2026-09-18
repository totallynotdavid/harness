# Adam Silver principles vs. this codebase

Method: read AGENTS.md and all 14 articles (one, "Native HTML components
don't guarantee good UX", 404s live — recovered via Wayback Machine), plus
`src/pages/*`, `FormField.tsx`, `Button.tsx`, `Header.tsx`, `Layout.tsx`. No
code changed.

**1. Obviousness over hidden patterns.** Affordances needing discovery cost
every user, not just touch users. AULA VIRTUAL's only explanation is a
`title` tooltip (`Header.tsx:87,138`) — invisible until hovered.

**2. Semantic HTML before ARIA.** Already good: real checkbox/select
elements, `role="alert"` on errors (`FormField.tsx:55`, `CarritoDatos.tsx:41`).
Gap: the AULA VIRTUAL `<span>` has no `aria-disabled`/role, so a visual-only
"próximamente" fix still announces nothing to AT (`Header.tsx:86-91`).

**3. Button placement** (primary aligned with the input column, no stray
secondary actions): already good, `Home.tsx:569`, `Contacto.tsx:102`.

**4. Validate on submit, not per keystroke.** `CarritoDatos.tsx:40-41,58-75`
does this correctly. But `CursoDetalle.tsx:94-97` — scout's named pattern
for R1 — only sets `submitted=true`, no `hasSubmitted`/`error` state,
relying purely on native `required`. Copying it literally gives R1 weaker
validation than the codebase's own best example.

**5. Never disable submit for invalid/incomplete state.** Already good
sitewide — no `disabled` submit button anywhere. R5's DNI lookup should keep
"Verificar" enabled and relabel it during the async check, not disable it
(`VerificacionCertificado.tsx:58-63`).

**6. Don't mark required fields; mark true optional ones.** `FormField.tsx:35-39`
asterisks every `required` field, and nearly every field across these forms
is required — a redundant asterisk everywhere (`Home.tsx:525-543`,
`Contacto.tsx:60-77`).

**7. Button text = verb + outcome.** Fine — "Enviar", "Verificar", "Ver
programa", not "Next/OK".

**8. Don't style nav as tabs unless it behaves like tabs.** Good — real
`<Link>`s with `aria-current` (`Header.tsx:64-71`).

**9. Page titles: `page - service`.** Already good — `Layout.tsx:22-23`.

**10. "Nobody wants to use your form."** Minimize friction, not decoration.
Home/Contacto ask 7 fields + 2 checkboxes for a marketing lead — worth
confirming each earns its place before R1 wires them as-is.

**11. HTML prototypes over Figma.** Process point — repo is already real
HTML/React. No finding.

**12. Placeholders disappear and shouldn't be the only instruction.**
Violated broadly: `Home.tsx:525-543`, `Contacto.tsx:60-77`,
`CursoDetalle.tsx:360-402` use a placeholder restating the label ("Nombres" /
"Nombres completos") as the sole hint. `VerificacionCertificado.tsx:49-57`
has permanent `helpText` but *also* a redundant placeholder — the noise
persists even where the fix is half-applied.

**13. Nativeness ≠ good UX; test the actual behavior.** The recovered
article names this site's exact failure: "the title attribute shows a
tooltip on hover, but doesn't work for keyboard users" — AULA VIRTUAL
verbatim (`Header.tsx:87,138`), a sharper reason than "touch users" for a
focusable replacement.

**14. Sticky menus promise proximity they don't deliver keyboard users, and
can hide the focused element.** New: `Header.tsx:29` sticks the whole
three-row header (location bar + nav) at `top-0 z-50` everywhere, untested
for obscuring focus at small widths.

## Highest-leverage new fixes (not in the prior scout report)

1. **Sticky header may obscure keyboard focus** (#14) — audit `Header.tsx:29`
   at small widths.
2. **Required-asterisk noise** (#6) — `FormField.tsx` marks every required
   field; since nearly all fields here are required, the asterisks are pure
   noise per Silver's rule.
3. **Placeholder-as-only-instruction** (#12) — every lead form uses
   placeholders as the sole hint; move real hint text into `helpText`,
   which `FormField` already supports.

## Corrections to R1/R5

- **R1**: wire forms after `CarritoDatos.tsx`'s pattern (submit-gated
  `error`/`hasSubmitted` via `FormField`'s `error` prop), not
  `CursoDetalle.tsx`'s — it has no error state to copy.
- **R5**: keep "Verificar" enabled through the lookup (relabel, don't
  disable); drop the placeholder duplicating `helpText`; skip the required
  asterisk on the single DNI field.
- **R4**: fix must be keyboard-focusable with a real accessible name/state,
  not only a non-hover visual cue — `title` tooltips are the article's own
  named failure case.
