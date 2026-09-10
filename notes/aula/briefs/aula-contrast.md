# aula-contrast: the subtle text token fails AA in both themes

You own `app/assets/css/main.css` and `app/pages/index.vue`. Nothing else.

## What is wrong

`--fg-subtle` does not reach the WCAG AA minimum of 4.5:1 for small text.
Measured against every surface it is used on:

| surface | light `#737373` | dark `#7a7a78` |
|---|---|---|
| `--bg` | 4.58 | **4.49** |
| `--bg-subtle` | **4.35** | **4.24** |
| `--bg-elevated` | 4.74 | **4.04** |

Four of six combinations fail. CI caught only one of them, because the
Lighthouse budget measures `/`, and `/` happens to use `--bg`, where light
passes by 0.08 and dark misses by 0.01. The dark job scores 0.87 against a 0.9
minimum and fails the build.

The numbers above are computed from the token values, not sampled from a
screenshot. Recompute them yourself before and after; the relative luminance
formula is in the WCAG 2 definition of contrast ratio.

## Deliverable

Choose `--fg-subtle` values for both themes that hold at least 4.5:1 on all
three surfaces, with enough headroom that a later background tweak does not
silently drop below. `#8a8a88` in dark reaches 5.58 / 5.27 / 5.02 and is a
worked example, not a decision: pick what looks right.

Two constraints on the choice:

- The hierarchy `--fg`, `--fg-muted`, `--fg-subtle` must stay visually
  distinct. Raising subtle until it reads as muted trades one defect for
  another.
- Check `--fg-muted` and every semantic colour (`--success`, `--warning`,
  `--danger`, `--accent`) on all three surfaces while you are in here. Report
  what you find even if you do not change it. Do not stop at the one token CI
  named.

## Deliverable 2: `/`

`app/pages/index.vue` is fourteen lines of placeholder: a label, a heading,
nothing else. It is the page CI measures and the first page anyone sees. Give
it real content: what CICAT is, what a visitor can do here without signing in
(verify a certificate, browse the course catalogue), and a way to reach both.

Both routes exist and are frozen to you. Link to them, do not rebuild them.

Design reference is `https://www.makingsoftware.com/`. Read the existing
pages under `layers/*/app/pages/` first and match what is already there
rather than introducing a second visual language.

## Verify

`pnpm build`, then `pnpm lighthouse` in **both** colour modes:

    export CHROME_PATH="$(pnpm exec playwright install --dry-run chromium |
      awk '/Install location/ { print $3; exit }')/chrome-linux64/chrome"
    LIGHTHOUSE_COLOR_MODE=dark pnpm lighthouse

Accessibility must reach 0.9 in both. The script-size warning is expected and
is not yours to fix. Delete `.lighthouseci/` before you finish.
