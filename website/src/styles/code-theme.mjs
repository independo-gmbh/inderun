/**
 * The Expressive Code theme for docs code blocks: the code plate is the black enamel in both
 * Starlight themes, as on the landing page (src/components/landing/CodePlate.astro). One dark
 * theme, so code never changes colour when the reader switches light and dark.
 *
 * Token colours are the --ir-code-* values from theme.css (lilac and off-white tints only; lilac
 * text is allowed on the enamel). They are repeated here as hex because Expressive Code checks
 * and adjusts token contrast at build time and needs real colours. Ratios are against #000 / the
 * dark-theme panel #0e0e0e used as the plate in the dark docs theme.
 *
 * The frame (plate background, edge, shadow, copy button) is styled through CSS variables set in
 * docs.css, so it can follow the page theme.
 */
import { ExpressiveCodeTheme } from "@astrojs/starlight/expressive-code";

const fg = "#faf5ef"; // 19.4:1 / 17.3:1
const keyword = "#a0b3ff"; // 10.4:1 / 9.3:1
const string = "#e2dbd2"; // 15.3:1 / 13.7:1
const constant = "#c9d3ff"; // 14.3:1
const comment = "#a8a39c"; // 8.4:1 / 7.5:1
const punctuation = "#bdb7af"; // 10.6:1 / 9.4:1

export const enamelCodeTheme = new ExpressiveCodeTheme({
  name: "inderun-enamel",
  type: "dark",
  colors: {
    "editor.background": "#000000",
    "editor.foreground": fg,
    "editor.selectionBackground": "#a0b3ff55",
    "terminal.foreground": fg,
    "terminal.background": "#000000"
  },
  tokenColors: [
    { settings: { foreground: fg } },
    { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: comment } },
    {
      scope: [
        "keyword",
        "storage",
        "storage.type",
        "storage.modifier",
        "keyword.operator.new",
        "keyword.control"
      ],
      settings: { foreground: keyword }
    },
    {
      scope: ["string", "punctuation.definition.string", "string.template"],
      settings: { foreground: string }
    },
    {
      scope: [
        "constant",
        "constant.numeric",
        "constant.language",
        "variable.language",
        "support.constant",
        "variable.other.enummember"
      ],
      settings: { foreground: constant }
    },
    {
      scope: [
        "punctuation",
        "meta.brace",
        "keyword.operator",
        "punctuation.separator",
        "punctuation.terminator"
      ],
      settings: { foreground: punctuation }
    },
    {
      scope: [
        "entity.name.function",
        "support.function",
        "entity.name.type",
        "support.type",
        "variable",
        "variable.parameter",
        "meta.property-name",
        "entity.other.attribute-name",
        "entity.name.tag"
      ],
      settings: { foreground: fg }
    },
    { scope: ["markup.bold"], settings: { fontStyle: "bold" } },
    { scope: ["markup.italic"], settings: { fontStyle: "italic" } }
  ]
});
