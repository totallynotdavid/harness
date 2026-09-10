# aula-secretariat: the console staff actually start their day on

You own `layers/secretariat/` and nothing else. It currently holds a
`/panel` page that says "Welcome, <name>." and an endpoint that returns that
string. Read `layers/secretariat/README.md` first: it explains why this layer
owns `/panel` while the guard that protects it stays in `layers/auth`.

## Why this exists

Everything a staff member does now lives on a screen someone has to know the
URL for. `/panel` is where they land, and it currently tells them their own
name, which they already knew. The point of this task is that a secretary
signing in at nine in the morning can see what needs doing and get to it.

## Deliverable 1: the overview endpoint, made real

`server/api/panel/overview.get.ts` keeps its `requirePermission(event,
'secretariat:access')` guard and returns the counts the console renders. One
route, one query pass, no per-card round trips.

Read across layers only through their `shared/` surfaces, which is the public
boundary. If a count you need is not reachable that way, report it rather than
importing a private module.

What is worth counting is what someone would otherwise chase by hand:
certificates awaiting release, deliveries waiting in the queue, courses with
ungraded students. Decide the exact set from what the schema can answer
cheaply, and say in your report which ones you chose and why.

## Deliverable 2: `/panel`, the console home

Not a dashboard of decorative statistics. Every number on it is a link to the
screen where that work gets done, and the screens already exist:
`/panel/entregas` (fulfilment), `/admin/catalogo` and `/admin/plantillas`
(catalog), `/cursos/[code]/notas` (grade capture). A separate task is building
`/panel/emision/[code]`; leave a place for it and do not build it yourself.

Requirements:

- The largest thing on the screen is the most urgent thing, not the logo.
- Zero-state is a real state. A secretary with nothing outstanding should see
  that plainly, not an empty grid.
- No loading spinner where a route rule or a single request would do. This
  page is authenticated, so it is never shared cache; make it fast by asking
  for less, not by animating the wait.
- Use `layers/base` primitives. Do not edit them.

## Deliverable 3: navigation

Staff currently reach `/admin/catalogo` and `/panel/entregas` by typing them.
Give the console a persistent way to move between staff screens, built inside
your own layer, driven by the viewer's permissions so a user never sees a link
to a page that will refuse them.

## Out of scope

The screens themselves. Catalog, courses, fulfilment and issuance are other
layers, landed or in flight, and frozen to you. You link to them and you
count what they own. You do not change them.
