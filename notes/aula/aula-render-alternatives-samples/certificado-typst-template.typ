// Typst candidate template for the Aula certificate renderer.
//
// Mirrors layers/certificates/server/render/template.ts's page geometry and
// content structure closely enough to judge Typst on the pipeline's own
// terms: exact A4-landscape page box, the three self-hosted fonts, an
// embedded QR SVG, and — the crux of this evaluation — a single-pass
// shrink-to-fit for the holder-name element using Typst's `measure()`,
// built to be as close as possible to shrinkToFit() in renderCertificate.ts:
// one measurement at a base size, one computed scale factor, no retry loop.
//
// Font note: Typst 0.15.1 cannot load the pipeline's .woff2 files directly
// (confirmed: `typst fonts --font-path <dir-with-only-woff2>` finds nothing;
// pointing --font-path at the fontTools-converted .ttf versions of the same
// files finds them under their internal family names). The names below,
// "Oswald" and "Tangerine", are those fonts' *actual* internal family names
// (the woff2 files are literally Google's Oswald/Tangerine renamed on disk
// per assets/fonts/README.md) — not the pipeline's logical family names
// "Aula Certificate Sans"/"Aula Certificate Script". Typst has no @font-face
// indirection to rename a family at load time, so keeping that logical-name
// abstraction would require either renaming the `name` table with fontTools
// during conversion, or hardcoding the vendor's real family name here and
// re-deriving it whenever the font file changes. See report.md.

#let holder-name = sys.inputs.at(
  "holder-name",
  default: "María Fernanda de los Ángeles Rodríguez-Villanueva y Quispe Huamán Salazar",
)

#set page(width: 297mm, height: 210mm, margin: 0mm)
#set text(font: "Oswald", weight: 500, lang: "es", size: 12pt)

#let accent = rgb("#103dff")
#let fg-muted = rgb("#52525b")
#let frame-pad-x = 20mm
#let frame-pad-y = 12mm
#let sheet-pad = 10mm
#let available-width = 297mm - 2 * sheet-pad - 2 * frame-pad-x

// --- Single-pass shrink-to-fit --------------------------------------------
// Exactly analogous to shrinkToFit() in renderCertificate.ts:
//   available = el.clientWidth
//   if scrollWidth <= available: no-op
//   else: fontSize = currentSize * (available / scrollWidth) * 0.98
// Typst's `measure()` gives the laid-out size of content without placing it
// on the page, inside a `context` block. That is the one Typst feature that
// makes a single measure-then-scale pass possible at all, the same role
// `el.scrollWidth` plays in the browser.
#let base-size = 52pt
#let name-content = text(font: "Tangerine", weight: 700, size: base-size, holder-name)

#let shrunk-name = context {
  let measured = measure(name-content)
  // calc.min(1.0, ...) mirrors the JS's implicit no-op-if-it-fits: the JS
  // only rewrites fontSize when scrollWidth > available, i.e. it never
  // *grows* text that already fits. Typst's measure equally never grows it.
  let scale = calc.min(1.0, available-width / measured.width * 0.98)
  text(font: "Tangerine", weight: 700, size: base-size * scale, holder-name)
}

#align(center)[
  #box(width: 297mm - 2 * sheet-pad, height: 210mm - 2 * sheet-pad, inset: 0pt)[
    #box(
      width: 100%, height: 100%,
      stroke: 1.2pt + accent,
      inset: (x: frame-pad-x, y: frame-pad-y),
    )[
      #set align(center)
      #text(size: 10pt, tracking: 0.08em, fill: fg-muted)[LIMA, PERÚ]
      #v(2mm)
      #text(size: 16pt, weight: 700, tracking: 0.04em)[CICAT — Centro de Capacitación]
      #v(8mm)
      #text(size: 30pt, weight: 700, tracking: 0.14em, fill: accent)[CERTIFICADO]
      #v(4mm)
      #text(size: 12pt, fill: fg-muted)[otorgado a]
      #v(5mm)

      #box(width: available-width)[
        #set align(center)
        #shrunk-name
      ]

      #v(5mm)
      #box(width: 190mm)[
        #set align(center)
        #set text(size: 13pt)
        en calidad de #text(weight: 700)[Participante] del curso
        #text(weight: 700)[Gestión de Riesgos en Minería Subterránea Ñoño],
        con una duración de 40 horas académicas, realizado del
        03 de marzo de 2026 al 28 de abril de 2026.
      ]

      #v(1fr)

      #grid(
        columns: (55mm, 55mm),
        column-gutter: 24mm,
        align: center,
        [
          #line(length: 100%, stroke: 0.6pt + black)
          #v(2mm)
          #text(weight: 700, size: 10.5pt)[Ana Torres Beraún]
          #linebreak()
          #text(size: 9.5pt, fill: fg-muted)[Directora Académica]
        ],
        [
          #line(length: 100%, stroke: 0.6pt + black)
          #v(2mm)
          #text(weight: 700, size: 10.5pt)[Luis Quiñones Peña]
          #linebreak()
          #text(size: 9.5pt, fill: fg-muted)[Coordinador de Curso]
        ],
      )

      #v(6mm)
      #grid(
        columns: (18mm, auto),
        column-gutter: 4mm,
        align: horizon,
        image("qr.svg", width: 18mm, height: 18mm),
        [
          #set text(size: 8pt, fill: fg-muted)
          #set align(left)
          Verifica este certificado en cert.aula.example/verify
          #linebreak()
          #text(fill: black, weight: 700)[ABC123XYZ]
        ],
      )
    ]
  ]
]
