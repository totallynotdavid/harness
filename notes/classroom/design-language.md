# The makingsoftware.com design language, and what transfers

Analysis of https://www.makingsoftware.com/, which the captain named as the UI reference,
and its translation into a Nuxt application.

Method note: the live site sits behind Vercel's bot checkpoint and refuses automated
fetches. Values below were read from Wayback Machine snapshots of the compiled CSS and
HTML (July and August 2026), with OKLCH tokens converted to hex. They are read, not
guessed.

## What the site actually does

Next.js with Tailwind v4. All fonts self-hosted through Next's font optimizer, with
metric-matched fallback faces, so there are zero third-party font requests.

**Typography: three faces, three jobs.**

- New York (Apple's system serif, self-hosted variable TTF) for chapter H1s only, at
  `text-4xl` (36px), centred, at `text-black/80` rather than pure black. One serif headline
  per page and nothing else.
- Inter, variable, for body and UI.
- Departure Mono, weight 500, for every piece of UI chrome that is not prose: eyebrow
  labels, nav, progress. A real class from the DOM:
  `truncate font-mono text-[0.6875rem] text-black/40 uppercase`. That is 11px monospace,
  uppercase, 40 percent black. **This is the most distinctive move in the design:
  monospace is the instrument-label voice, not a code font.**

The scale is mostly stock Tailwind and stops at `text-4xl`. No display type. Measure is
`max-w-prose` at 65ch, inside `max-w-5xl` chapter columns, inside a `grid-cols-5 gap-x-10`
page shell.

**Colour: one deliberate pair and one accent, everything else default.**

The base is `--background: #fbfbfb` and `--foreground: #171717`. Not white and black. That
six-points-off-white against nine-percent-off-black reads as paper rather than as a
browser default, and it is the cheapest high-leverage substitution available.

One accent, a custom cobalt not in stock Tailwind: `--color-cobalt-600` resolves to
**#103dff**. It appears on hover, outline and a 1px divider. It essentially never appears
as a fill. Every other colour is stock Tailwind gray, unmodified. The restraint is the
decision.

Dark mode is shallow: the only `.dark` rules are inside the typography plugin's `.prose`
scope. The chrome has no dark variant. It is a light-primary editorial site.

**Texture, which is the load-bearing part.**

The figure-card recipe, verbatim from a live chapter:

    rounded-xs p-8 md:bg-white
    md:shadow-[0px_1px_4px_1px_rgba(0,0,0,0.05),
               0px_1px_1px_0px_rgba(0,0,0,0.50),
               0px_-1px_1px_1px_#FFF_inset]

Three layers: a soft 4px ambient blur at 5 percent, a tight dark 1px contact shadow at
**50 percent**, and a 1px inset white top highlight. It reads as a physical card lit from
above and resting on the page. It deliberately bypasses Tailwind's own shadow tokens,
which exist unused in the same file, because they were not dramatic enough.

Corners are nearly square. Only `rounded-xs` (2px) and `rounded-sm` (4px) appear anywhere
in the shipped CSS. No pills, no `rounded-lg`.

There is a near-invisible background texture: a 3x3px SVG tile holding one 1px line in the
accent cobalt at 15 percent stroke opacity. A hairline grain nobody consciously perceives,
tinted with the brand hue, tying surfaces back to the accent even where no colour is
visible.

Motion is restrained to `duration-200` and `duration-300` fades on hover, opacity and
colour. No spring, no page-transition choreography.

**Thesis.** It borrows the grammar of a technical field guide: paper-toned neutrals, a
single accent used only as an instrument signal and never as a fill, monospace doing the
job of specimen labels, machined rather than soft corners, and a hand-tuned shadow that
makes each diagram a physical object under a light. A cheap imitation gets three things
wrong: it reaches for a generic `shadow-lg` instead of the contact-plus-inset-highlight
recipe; it treats mono as "for code" rather than "for labels and metadata everywhere"; and
most importantly it mistakes the tokens for the design, when most of what makes the site
feel expensive is bespoke per-chapter interactive diagram work that is not a token anyone
can copy.

## The closest open-source reference

**npmx.dev** (`npmx-dev/npmx.dev`, Nuxt 4) is the closest structural match and, unlike
makingsoftware.com, it is an *application*: tables, search, code viewers, badges, a theme
picker. It shares the instincts — near-monochrome base, one accent, mono on UI chrome,
small radii, OKLCH tokens — applied to application surfaces.

What it does concretely: UnoCSS with `presetWind4` rather than Tailwind; design tokens as
hand-written plain CSS custom properties in `app/assets/main.css` (`--bg`, `--bg-subtle`,
`--bg-elevated`, `--fg`, `--fg-muted`, `--border`, `--accent`) gated behind
`:root[data-theme='dark']` attribute selectors rather than `prefers-color-scheme` alone,
with a second layer of user preference on top (`data-bg-theme`, `data-fg-theme`); dark
mode through `@nuxtjs/color-mode` writing `data-theme` onto `<html>`; fonts through
`@nuxt/fonts` with `provider: 'local'` for Geist and Geist Mono; and components hand-rolled
in plain Vue with utility classes, no component library imported at all.

Also worth reading: **bun.sh** for even tighter radii (2 to 6px) and `--shadow: none` in
light mode, leaning entirely on borders; **astro.build** (`withastro/astro.build`) for the
identical display-plus-sans-plus-mono triad, self-hosted as variable woff2 with
hand-authored fallback metrics; and **ui.shadcn.com** as the thing to consciously override,
since its `--radius: .625rem` and pure black-on-white are exactly the generic register to
avoid.

## Translation to Nuxt

**Components.** Hand-rolled on Tailwind v4 utilities with CSS custom-property tokens, using
reka-ui only for primitives that need real accessibility engineering: dialog, popover,
select, combobox, menu, tooltip. Not Nuxt UI wholesale, not shadcn-vue wholesale. The
reasoning is that npmx.dev, the one genuinely application-shaped Nuxt app in the
comparison set, makes exactly this choice, and a component kit is opinionated on precisely
the details that carry this identity: radius, shadow, accent usage. The cost is slower
initial velocity on basic elements, and it is real.

**Typefaces**, through `@nuxt/fonts` so metric-matched fallbacks are generated rather than
hand-computed: Inter variable for sans; **Geist Mono** for chrome rather than Departure
Mono, because Departure Mono's stylised letterforms lose legibility in dense tables at 12
to 13px, and Geist Mono is already validated in npmx.dev's real data tables; Newsreader or
Fraunces for the rare editorial moment, both SIL OFL, in the same restrained book-serif
register as New York without its web-licensing murk.

**Palette**, following npmx.dev's `data-theme` attribute pattern so users can override the
OS setting:

    :root, :root[data-theme='light'] {
      --bg: #fbfbfb;  --bg-subtle: #f5f5f5;  --bg-elevated: #ffffff;
      --fg: #171717;  --fg-muted: #52525b;   --fg-subtle: #737373;
      --border: #e5e5e5;  --border-strong: #d4d4d4;
      --accent: #103dff;  --accent-fg: #ffffff;  --accent-muted: #e6ebff;
      --success: #15803d; --warning: #b45309;   --danger: #e7000b;
      --radius-xs: .125rem; --radius-sm: .25rem; --radius-md: .375rem;
      --shadow-card: 0 1px 4px 1px rgba(0,0,0,.05),
                     0 1px 1px rgba(0,0,0,.5),
                     inset 0 -1px 1px 1px #fff;
    }
    :root[data-theme='dark'] {
      --bg: #0d0e11;  --bg-subtle: #14151a;  --bg-elevated: #1a1a1c;
      --fg: #eaeae8;  --fg-muted: #a8a8a5;   --fg-subtle: #7a7a78;
      --border: #282a36;  --border-strong: #3b3f4b;
      --accent: #6b86ff;  --accent-fg: #0d0e11;  --accent-muted: #1c2340;
      --success: #34d399; --warning: #f5b43c;   --danger: #ff5a5a;
      --shadow-card: 0 1px 4px 1px rgba(0,0,0,.4),
                     0 1px 1px rgba(0,0,0,.7),
                     inset 0 1px 1px 0 rgba(255,255,255,.06);
    }

Spacing stays on Tailwind's stock 4px base. The type scale should use Tailwind's full
default rather than makingsoftware.com's sparse five-step subset, because a dashboard needs
the intermediate steps it skips: 18px card titles, 30px stat numbers, 14px as the workhorse
table and form size.

**The four details that do most of the work.** The off-white and off-black base pair,
never pure white or black. Mono on UI chrome — table headers, status badges, timestamps,
kicker labels, stat units — uppercase, tracked wide, small, muted. The contact-plus-inset
shadow reserved for a small number of genuinely elevated surfaces per screen, with flat 1px
borders on everything that repeats. And the accent-tinted hairline texture on large empty
regions, empty states and skeletons.

**What does not transfer.** The 65ch measure is a reading constraint; tables and dashboards
need the width, so reserve it for actual prose. The card shadow cannot ride on 200 table
rows without becoming noise and a paint cost. The bespoke interactive diagrams are the
wrong asset class and are inimitable at that investment anyway; what replaces them is
restrained data visualisation under the same colour discipline, neutral series in gray with
exactly one highlighted in the accent. The centred single-column grid does not fit a
sidebar-plus-content shape; borrow the generous gutters and the sticky backdrop-blurred
header, not the literal five-column layout. And the editorial devices, the global wavy
underline and the centred serif headline, belong to an author explaining something. App
copy is transactional.
