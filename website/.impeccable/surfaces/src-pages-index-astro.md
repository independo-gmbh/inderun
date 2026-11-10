---
version: 1
slug: "src-pages-index-astro"
primary_target: "src/pages/index.astro"
related_targets: ["src/pages/imprint.astro","src/pages/privacy.astro"]
---

# Surface brief: inderun.dev landing page (`/`)

Mode: Persuade. Related surfaces: the Starlight docs theme (Read mode) and `/imprint`, `/privacy` inherit this world.

Audience and job: Capacitor developers deciding in one screenful whether IndeRun solves "what does my app do when the
on-device model isn't there", then starting the quickstart. Action: "Get started with Capacitor" →
`/docs/getting-started/capacitor`. Proof: the type-checked local-only snippet, the device panel, the per-platform list of what each model needs. Constraints: copy from brief §3 + §8.4 verbatim in meaning; attribution in hero;
no claims beyond released code; WCAG 2.2 AA; static first; no client JS needed to read anything.

## Direction contract

THESIS: A request is a train and IndeRun is the interlocking: the app sets a rule, and the panel physically cannot clear
a route the rule forbids. Refuses the category default of hero text + glossy code card + three icon tiles.

OWN-WORLD: A black enamel signal-box panel set into off-white #FAF5EF ground. White engraved route lines, ghost lines for
routes never cleared, lilac #A0B3FF route lamps as the only colour, square push-button controls, engraved Inter caps
plates, tabular numerals, mono only inside code.

STORY: One call enters; it reaches the devices people actually have. Three lanes end on the device's own model
(Apple Foundation Models, Gemini Nano, Chrome built-in AI), the fourth (no local model) ends in a lit, labelled
refusal, or in the app's own cloud only when the rule allows it. First glance answers "why would I need this": the
model is not on every device, and IndeRun makes one rule hold on all of them. Each section below answers the next
question a developer asks (what it runs on, why the model is missing, what the code looks like, what comes back,
speech, data, fit), and caveats sit one click down in a <details>.

FIRST VIEWPORT (revised 10 Nov 2026 on owner feedback: hero too wordy, illustration needs recognisable logos and
fewer words): Left column: H1 tagline, the support line, one sentence naming the three engines, primary + secondary
CTA, and one small credits line at the hero's foot (open source on GitHub, Independo, netidee). No eyebrow. Right
(stacked below on phones): the panel "One call. Every device.": an entry plate `ai.run(task)`, four lanes with a
monochrome mark key (Apple, Google Gemini, Google Chrome, a Lucide phone glyph), engine name + device line, track,
and a lamp tablet (ON DEVICE ×3, REFUSED or YOUR CLOUD). Signature interaction: a two-key rule switch
(`local_required` / `local_preferred`, native radios, CSS `:has()`) that swaps the last lane between the stop +
REFUSED and a dashed line + YOUR CLOUD. Readable with no JS, no colour and no motion. Third-party marks come from
Simple Icons; their notices are on /notices. UI icons are Lucide. Styling is Tailwind; the page has a dark theme
(black ground, the panel lifted one step) shared with the docs' theme switch.

FORM: Railway interlocking route-setting panel; position 1 on my ordered list (Impeccable's pick, chosen by the owner
over the assigned ladder-logic schematic); seed key 9d5e7dca.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Unresolved

- Approved netidee asset (using the independo.app copy until confirmed), plus a negative (light-on-dark) version for the dark theme; until then the logo sits on a small paper plate.
- OG image (1200×630 JPEG) to be rendered from the built panel.
