---
name: inderun.dev
description: The IndeRun site as a railway-interlocking panel, a black enamel route-setting panel set into an off-white ground, with a black-ground dark theme.
colors:
  lamp: "#a0b3ff"
  ground: "#faf5ef"
  ground-sunk: "#f1eae1"
  ink: "#000000"
  ink-body: "#24211e"
  ink-muted: "#4a4641"
  ink-faint: "#67625b"
  rule: "#d6cec3"
  edge: "#8c857c"
  panel: "#000000"
  panel-raised: "#121212"
  panel-rule: "#3a3835"
  panel-edge: "#969390"
  engrave: "#faf5ef"
  engrave-muted: "#bdb7af"
  ground-dark: "#000000"
  ground-sunk-dark: "#121212"
  ink-faint-dark: "#a8a39c"
  rule-dark: "#2e2c2a"
  edge-dark: "#8f8a83"
  panel-dark: "#0e0e0e"
  panel-raised-dark: "#1a1a1a"
  code-string: "#e2dbd2"
  code-constant: "#c9d3ff"
  code-comment: "#a8a39c"
typography:
  display:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(2.375rem, 1.25rem + 3vw, 4rem)"
    fontWeight: 750
    lineHeight: 1
    letterSpacing: "-0.04em"
    fontFeature: '"cv11", "ss01"'
  headline:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(1.75rem, 1.3rem + 1.6vw, 2.5rem)"
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: "-0.03em"
  title:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(1.25rem, 1.05rem + 0.75vw, 1.5rem)"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.015em"
  body:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.625
  small:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 400
  meta:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.8125rem"
    fontWeight: 400
    lineHeight: 1.375
  label:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 600
    letterSpacing: "0.1em"
  plate:
    fontFamily: "Inter, Inter Fallback, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "0.1em"
  code:
    fontFamily: "ui-monospace, SF Mono, SFMono-Regular, Menlo, Consolas, Liberation Mono, monospace"
    fontSize: "0.875em"
    fontWeight: 400
rounded:
  key: "2px"
  plate: "3px"
  panel: "4px"
spacing:
  gutter: "clamp(1rem, 4vw, 3rem)"
  site: "86rem"
  legal: "44rem"
components:
  push-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
    rounded: "{rounded.plate}"
    height: "2.875rem"
    padding: "0.6875rem 1.125rem"
  push-primary-hover:
    backgroundColor: "{colors.lamp}"
    textColor: "{colors.ink}"
  push-primary-dark:
    backgroundColor: "{colors.lamp}"
    textColor: "{colors.ink}"
    rounded: "{rounded.plate}"
    height: "2.875rem"
    padding: "0.6875rem 1.125rem"
  push-primary-dark-hover:
    backgroundColor: "{colors.engrave}"
    textColor: "{colors.ink}"
  push-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.plate}"
    height: "2.875rem"
    padding: "0.6875rem 1.125rem"
  push-secondary-hover:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
  push-small:
    rounded: "{rounded.plate}"
    height: "2.5rem"
    padding: "0.5rem 0.875rem"
    typography: "{typography.small}"
  panel:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.engrave}"
    rounded: "{rounded.panel}"
    padding: "1.5rem"
  panel-dark:
    backgroundColor: "{colors.panel-dark}"
    textColor: "{colors.engrave}"
    rounded: "{rounded.panel}"
  lane-key:
    backgroundColor: "{colors.panel-raised}"
    textColor: "{colors.engrave}"
    rounded: "{rounded.key}"
    size: "2.25rem"
  tablet:
    backgroundColor: "{colors.panel-raised}"
    textColor: "{colors.engrave}"
    rounded: "{rounded.plate}"
    typography: "{typography.plate}"
    height: "2.25rem"
    padding: "0.375rem 0.625rem"
  entry-plate:
    backgroundColor: "{colors.panel-raised}"
    textColor: "{colors.engrave}"
    rounded: "{rounded.plate}"
    typography: "{typography.code}"
    padding: "0.375rem 0.625rem"
  rule-switch-key:
    backgroundColor: "transparent"
    textColor: "{colors.engrave-muted}"
    rounded: "{rounded.key}"
    padding: "0.375rem 0.625rem"
  rule-switch-key-set:
    backgroundColor: "{colors.lamp}"
    textColor: "{colors.ink}"
  requirement-plate:
    backgroundColor: "{colors.ground-sunk}"
    textColor: "{colors.ink}"
    rounded: "{rounded.plate}"
    padding: "0.375rem 0.625rem"
  theme-select:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.ink}"
    rounded: "{rounded.plate}"
    height: "2.5rem"
    typography: "{typography.small}"
---

# Design System: inderun.dev

## Overview

**Creative North Star: "The Interlocking Panel"**

The site is built as a railway interlocking: a black enamel route-setting panel set into an off-white ground. Routes are drawn as flat engraved track, ends are lamp tablets, controls are square push keys, labels are engraved caps plates. The hero panel ("One call. Every device.") is the proof of the product's claim: one `ai.run(task)` call enters on a single trunk and reaches four lanes, three ending on the device's own model and the fourth, "No local model", ending in a stop and a REFUSED tablet, or in YOUR CLOUD only when the rule switch allows it.

The surface is flat and engineered. The ground carries reading; the panel carries decisions. Independo's brand is used selectively: off-white, black, lilac, Inter. The IndeRun logo (from the 2026-11-10 logo package: the INDERUN wordmark with RUN in a lilac code-span block) marks the header and footer. Third-party platforms are identified by monochrome Simple Icons marks (attributed on /notices); interface icons are Lucide at one stroke width (1.75). The site has two themes sharing Starlight's storage and attribute: the light theme is the paper, the dark theme is a black ground with the panel lifted one step off it. Without JavaScript the OS setting decides. Docs reuse the same world in Read mode.

**Key Characteristics:**

- Two grounds per theme: paper and black panel in light; black ground and a lifted near-black panel in dark.
- Lilac is light: a lamp, a lit key, a background behind black text, or a line or text on black.
- Every outcome is readable as words and symbols with no colour, motion or JavaScript.
- Flat fills, hairline edges, 2 to 4px corners, no decorative gradients beyond the panel's tile seams.
- WCAG 2.2 AA, 3px focus rings, Inter self-hosted, no third-party resources except Google Analytics (cookieless until the visitor accepts cookies).

## Colors

A near-monochrome paper-and-black palette with a single lilac lamp. Every colour is a theme-switching `--ir-*` variable in `src/styles/theme.css`, mapped to semantic Tailwind names (ground, ink, panel, engrave, lamp) through `@theme inline`, so components never need a `dark:` variant for colour. Contrast ratios are annotated in that file.

### Primary

- **Lamp Lilac** (`lamp`): the only colour. Fill of lamp tablets, the set key of the rule switch, the dark theme's primary push button, the current docs sidebar item, selection and the draft banner, always with black text (10.4:1). As text or line only on black: `task` in the entry plate, code keywords, the lilac focus ring on the panel and in the dark theme, the link underline in the dark theme.

### Neutral

- **Paper Ground** (`ground`) and **Paper Sunk** (`ground-sunk`): page ground and inset plates (requirement plates, inline code, docs asides and group plates, the panel's recess ring).
- **Ink** (`ink`, 19.4:1), **Ink Body** (`ink-body`), **Ink Muted** (`ink-muted`, 8.6:1), **Ink Faint** (`ink-faint`, 5.6:1, faintest allowed text). In the dark theme the ink steps invert to off-white, #e2dbd2, #bdb7af and `ink-faint-dark`.
- **Rule** (`rule`, `rule-dark`): decorative hairlines. A strong rule (1.5px, ink in either theme) heads lists, tables and the footer. **Edge** (`edge`, `edge-dark`): field and unlit-lamp outlines at the 3:1 non-text floor.
- **Panel** (`panel`, black in light; `panel-dark`, #0e0e0e in dark) and **Panel Raised** (`panel-raised`, `panel-raised-dark`): the panel and the keys, plates and tablets set into it. **Panel Rule** (`panel-rule`) its hairlines; **Panel Edge** (`panel-edge`, 6.9:1) key and switch outlines; plate edges are off-white at 24%; tile seams off-white at 5%.
- **Engrave** (`engrave`) and **Engrave Muted** (`engrave-muted`): text on the panel, in both themes.
- **Code** on the panel: foreground off-white, keyword lilac, string `code-string`, constant `code-constant`, comment `code-comment`, punctuation #bdb7af.

### Named Rules

**The Lilac Rule.** Lilac is a lamp or a background with black text on it. Lilac text and lines appear only on black or near-black: the panel in both themes, and the page in the dark theme. Lilac text on off-white is never allowed (1.9:1).

**The Two Grounds Rule.** Paper reads, the panel decides. Each theme has exactly one reading ground and one panel; in the dark theme the panel lifts one step (#0e0e0e) and keeps its own hairline. Do not introduce a third surface colour or a tinted card.

## Typography

**Font:** Inter (variable, 100 to 900, self-hosted woff2, SIL OFL, preloaded), with a metric-matched "Inter Fallback" (local Arial, size-adjust 107.4%) to hold layout. Features "cv11", "ss01". **Mono:** system monospace stack, only for code and the API names on the panel (`ai.run(task)`, `local_required`, `local_preferred`).

**Character:** One family, differentiated by weight and tight tracking at large sizes; engraved caps for plates. Inter is binding.

### Hierarchy

- **Display** (750, fluid 2.375rem to 4rem, 1.0, -0.04em): hero title only, max 15ch.
- **Headline** (700, fluid 1.75rem to 2.5rem, 1.08, -0.03em): section titles, max 24ch.
- **Title** (600, fluid 1.25rem to 1.5rem, 1.3, -0.015em): hero support line; 500 for the closing fit paragraph.
- **Body** (400, 1rem at 1.625; section prose at 1.125rem): max 42 to 80ch. Docs body 1.0625rem at 1.7.
- **Small** (0.9375rem): footer, compact controls, theme select, caveats inside `<details>`.
- **Meta** (0.8125rem): the device line under each engine name and the entry plate.
- **Label / Plate** (600, engraved caps through the `caps` utility: uppercase, 0.1em, tabular numerals; 0.75rem for code-plate captions, docs table heads, aside titles and tablets; nothing smaller): used inside plates and tables, never as a line above a heading.
- Links in the header and footer are 550.

### Named Rules

**The Real Text Rule.** Every label, outcome and rule is real HTML text; SVG only draws marks, icons and nothing that has to be read.

## Layout

One page container everywhere: 86rem maximum (80rem of content plus the widest gutter), centred, with a fluid gutter (clamp 1rem, 4vw, 3rem). The hero is a two-column grid from 64rem (copy 1fr, panel 1.1fr, column gap 4rem); the panel spans both hero rows, the copy sits at the foot of the first and a small credits line (MIT on GitHub, Independo, netidee on a paper logo plate) sits under it behind a hairline. Below 64rem the order is copy, panel, credits, so the credits move below the panel on phones. The "Runs on" strip is a single row between two hairlines. Sections below follow a legend-like rhythm at 5rem top spacing (7rem from 64rem): ruled lists headed by a 1.5px strong rule rather than tiles, a two-column 4/8 row layout from 48rem, the code example beside its heading at 4/7, and caveats one click down in a `<details>`. The closing block is a second panel. The device panel switches to its wider lane layout at a 28rem container width. The header collapses below 40rem into a disclosure sheet only when JavaScript runs; without it the links wrap. The footer is a 1.5px top rule with the shared attribution block, two columns (5/7) from a 47.84rem container width. Legal pages use a 44rem column.

## Elevation & Depth

Flat, with depth only as physical set-in. The panel is recessed into the ground by a stacked ring (`shadow-set-in`: an inset panel-rule hairline, 5px of ground-sunk, 1px of rule) that follows the theme; plates and keys are one tone lighter than the panel. In the dark theme the panel itself lifts one step off the black ground. The primary push button carries a small drop; the mobile menu sheet a long soft shadow; the code plate on light docs a soft lift.

### Shadow Vocabulary

- **Set-in** (`box-shadow: inset 0 0 0 1px var(--ir-panel-rule), 0 0 0 5px var(--ir-ground-sunk), 0 0 0 6px var(--ir-rule)`): the device panel, the closing panel, the code plate.
- **Push** (`box-shadow: 0 1px 0 rgb(0 0 0 / 0.2), 0 8px 18px -10px rgb(0 0 0 / 0.55)`): primary push button only.
- **Sheet** (`box-shadow: 0 18px 30px -22px rgb(0 0 0 / 0.45)`): the open mobile menu.
- **Docs code plate, light** (`box-shadow: inset 0 1px 0 rgb(255 255 255 / 0.1), 0 1px 3px rgb(0 0 0 / 0.14), 0 16px 32px -24px rgb(0 0 0 / 0.42)`): Expressive Code frames on the light docs.

### Named Rules

**The Set-In Rule.** Depth means "mounted into the ground": rings, insets, and one-tone-lighter plates, never floating cards.

## Shapes

Small, near-square corners: 2px keys and focus rings, 3px buttons, plates, tablets, inline code and the theme select, 4px panels, 1px for the push button's square lamp indicator and the code-plate caption mark, full circles only for lamps. Edges are hairlines (1px) or 1.5px ink on controls and strong rules. Track is 3px engraved line: a trunk down the left of the lanes ending at the last junction, a short junction into each lane, a line to the tablet; the refused lane ends in a vertical stop bar, the permitted cloud lane is a dashed line (0.5rem dash, 0.375rem gap). Tile seams are a 2.25rem grid.

## Components

### Push buttons

Square-cornered (3px), 1.5px border, 600 weight, `Push.astro`, shared by the landing header, the hero and the docs header. Sizes: default 2.875rem, small 2.5rem, compact 2.25rem. **Primary, light:** black, off-white text, a square lilac indicator before the label; hover lights lilac with black text and a black indicator. **Primary, dark:** the lit lamp, black text and indicator; hover turns paper. **Secondary:** transparent with an ink border; hover fills ink. Press translates 1px; transitions 160ms on the exponential ease-out.

### Arrow link

Inline semibold text link with a Lucide arrow (1.75 stroke) kept on the same line as the last word; the arrow moves 0.25rem on hover. Ends a section with its next step.

### Device panel (signature)

"One call. Every device." on the black panel with tile seams and the set-in ring. Header row: title and a two-key rule switch (a fieldset of native radios, `local_required` / `local_preferred` in mono; the set key is lilac with black text). An entry plate `ai.run(task)` feeds a single trunk into four lanes. Each lane: a square key holding a monochrome mark (Apple, Google Gemini, Google Chrome; a Lucide phone for "No local model"), the engine name over a muted device line, track, and a tablet. Three tablets read ON DEVICE with a lit lamp; the last reads REFUSED (Lucide ban, stop bar) or, with `local_preferred`, YOUR CLOUD (Lucide cloud, dashed line). The swap is CSS `:has()`, no JavaScript; without `:has()` the default rule shows. A footer line states the consequence in words and links to the routing page with a lilac underline.

### Outcome headings

The outcomes section is headed by the panel's own tablets set on the paper (ON DEVICE, REFUSED, YOUR CLOUD), each over its explanation and the exact field it reports, so the page and the panel name outcomes identically.

### Reason plates

Sunk plates (ground-sunk, rule inset ring, 3px) each carrying a Lucide icon (1rem, stroke 1.75) and one condition a platform needs to run on-device, grouped per platform beside its Simple Icons mark.

### Code plate

Black figure (the lifted panel in dark) with the set-in ring, an engraved caps caption behind a square lilac mark, Shiki css-variables theme from the `--ir-code-*` tokens, a focusable scroll region, and the rule line marked with a lamp in the gutter on a faint lilac wash. Black in both themes.

### Navigation

Logo left (140px wide, `src/components/Logo.astro`); links in 550 weight, current page underlined 2px; a theme select (native select on a 3px plate with a Lucide sun, moon or monitor and a chevron, shown only with JavaScript); a small primary push. Below 40rem with JavaScript a 1.5px bordered square Menu button (fills ink when open) opens a ground-coloured sheet with ruled rows, a 1.5px ink bottom edge and the sheet shadow.

### Consent banner

A small black panel (the set-in ring, 4px corners) docked bottom left, 30rem wide, full width less 0.75rem on phones; it never covers the page or traps focus. It asks for analytics cookies only: Google Analytics runs cookieless either way. Heading "Analytics cookies", one short muted paragraph with a lilac-underlined "Privacy notice" link, and two identical panel keys, Accept and Decline (raised panel fill, 1.5px panel-edge border, engrave text; the border turns engrave on hover). Neither key is lit: the choices carry the same weight. It follows the skip link in the DOM, so it comes before the content in the tab order. A footer "Cookie settings" button, styled as a footer link, reopens it and moves focus to its heading.

### Inputs / Fields

Only the theme select: ground fill, 1px edge outline (3:1), ink border on hover, 3px corners, 2.5rem tall, small text.

### Docs (Starlight, Read mode)

Starlight via `@astrojs/starlight-tailwind`; its variables map to the same `--ir-*` tokens, so light is paper and dark is the black ground. Headings 2.125rem (2.75rem from 50em), body 1.0625rem at 1.7. The current sidebar item is the lit route (black on lilac); top-level groups are engraved plates; the current TOC heading carries a lamp. Links underlined, lilac underline in dark. Asides, tables and inline code are sunk plates with 3px corners and caps labels; aside kinds are named in the label, never by colour alone.

### Attribution and legal

One shared attribution block in both footers: the endorsed logo ("by Independo.", 160px), Independo and netidee line, four labelled link groups (Docs, Source, About, Legal; caps headings) laid out by container query, and a copyright line (2025 to the build year). Legal pages: 44rem column, `LegalFact` rows (muted term beside value, ruled), a lilac draft banner with black text, dashed-border placeholders.

## Do's and Don'ts

### Do:

- **Do** use lilac only as a lamp, as a background behind black text, or as text and lines on black.
- **Do** keep every outcome legible as words and symbols without colour, motion or JavaScript.
- **Do** use 3px focus rings: ink on paper, lilac on the panel and in the dark theme.
- **Do** build controls as real elements (radio, select, button, link); keep the 2.5rem minimum target.
- **Do** take colours from the semantic theme tokens so both themes follow without a `dark:` colour variant.
- **Do** use Lucide (stroke 1.75) for interface icons and monochrome Simple Icons for third-party marks, always next to the name they identify.
- **Do** self-host Inter and load no third-party resources; the only exception is Google Analytics, which stays cookieless until the visitor accepts.
- **Do** open every link that leaves inderun.dev in a new tab. `src/middleware.ts` adds `target="_blank"`, `rel="noopener"` and a screen-reader "(opens in new tab)" to the rendered HTML, so pages and components never set it by hand.
- **Do** keep motion to the exponential ease-out (cubic-bezier(0.16, 1, 0.3, 1)), 160 to 200ms, and honour reduced motion.

### Don't:

- **Don't** set lilac text on off-white.
- **Don't** recolour the logo's RUN block, set the wordmark in Inter, or use the logo below its minimum width (120px, endorsed 160px).
- **Don't** add cards, gradient fills, or hard offset shadows; depth is set-in only.
- **Don't** convey an outcome by colour or animation alone.
- **Don't** use a different typeface for display; Inter is binding.
- **Don't** give Accept more weight than Decline in the consent banner, or set analytics cookies before the visitor accepts.

Defects and drift not canonized: the closing panel's two buttons are hand-built push variants (paper key with a lilac indicator, outlined panel key) instead of `Push.astro`; the panel title, the closing heading and the legal page heading use one-off sizes outside the type ramp.
