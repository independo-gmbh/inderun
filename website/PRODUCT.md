# Product

<!-- impeccable:product-schema 1 -->

Internal design context for the inderun.dev website, used by the Impeccable design workflow. It is not published.
Source: the IndeRun developer website brief (Notion, 9 Nov 2026), confirmed by the owner on 9 Nov 2026.

## Platform

web

## Users

- **Primary:** Capacitor developers who want to add on-device AI (Apple Foundation Models on iOS, Gemini Nano via ML Kit
  GenAI on Android) to a cross-platform app, and need to know what happens when the model is not there.
- **Secondary:** Web/TypeScript, Swift and Kotlin developers using the platform SDKs directly.
- **Reviewers:** netidee and partners checking the site as public, reproducible evidence of funded open-source results.

## Product Purpose

IndeRun is an open-source (MIT), privacy-aware AI execution SDK for cross-platform apps, built and maintained by
Independo GmbH. The site makes IndeRun legible and reproducible: what it does, whether it fits, how to run a first
local-only request, and what a refusal means. It supports netidee publication and Independo's own products. It is not a
SaaS launch: no signup, pricing, blog, hosted service or lead capture. Success means a developer understands "on-device
when available, refused or cloud only if allowed" and reaches a success or an understood refusal from the quickstart.

## Positioning

One normalized execution contract and policy-controlled routing across iOS, Android and the web. Each request carries a
rule: `local_required` runs on the device or is refused before anything executes; `local_preferred` may use a cloud
provider only if the app configured one and the request permits it. Every result or refusal reports what happened
(capability snapshots, normalized errors, provenance). Single-platform plugins wrap one model; none of them applies one
rule across platforms and reports the outcome. IndeRun does not win by claiming more models or universal on-device AI.

## Operating Context

Developers arrive from Google, GitHub and npm, often with a problem query ("Apple Foundation Models not available
fallback", "Gemini Nano not available", "speechSynthesis voices offline"). They read code first, test on physical
devices, and need exact build-failure strings and pinned versions. The site launches the same day as IndeRun v0.5.0 and
a Capacitor plugin release; versions come from `website/versions.json`.

## Capabilities and Constraints

- Shipped: text `run()` / `stream()`, capability checks, provenance, routing constraints; speech `speak()`,
  `generateSpeech()`, `listVoices()` with system voices (v0.5.0).
- Speech locality differs per platform: Android enforces `local_required` via each voice's network flag; Apple voices
  are assumed local (no flag in the API, airplane-mode check pending); on the web `local_required` speech is always
  refused.
- Not shipped and never shown as shipped: Mode 3 sessions, edge providers, the Mistral/open-weight iPhone fallback,
  offline claims without a recorded airplane-mode test.
- Site analytics: Google Analytics 4 in advanced Consent Mode. Cookieless pings by default, cookies only after the
  visitor accepts them in the consent banner; none at all when the browser sends Global Privacy Control; never on
  preview builds. Approved in legal review; described in the privacy notice. No SDK usage telemetry; the SDK's `telemetry` is a local hook only.
- Undecided: approved netidee asset, documentation licence (CC BY-SA 4.0
  per the netidee plan, to be confirmed).

## Brand Commitments

- Independo identity used selectively: off-white `#FAF5EF`, black `#000000`, lilac `#A0B3FF`, Inter.
- IndeRun logo from the approved logo package (2026-11-10); no other brand system without separate approval.
- "Built and maintained by Independo" and netidee credit visible in the hero.
- Voice: precise, friendly, technical; local first, never cloud first. Neutral language about users and devices
  ("people use older phones"); IndeRun is an execution layer, not a model or an accessibility certification.

## Evidence on Hand

- Released packages and source: `@independo/inderun-web`, `@independo/capacitor-inderun`, SwiftPM, Maven Central.
- Type-checked code examples in `website/snippets/`.
- netidee logo: `website/src/assets/netidee.svg` (from independo.app; approval to confirm).
- Absent and never to be fabricated: device test results for the site, testimonials, customer logos, benchmarks,
  download counts as adoption, offline results.

## Product Principles

1. Local first: the on-device rule leads every surface; cloud is opt-in and shown as conditional.
2. A refusal is a correct outcome, not an error to hide.
3. Claims follow released code and recorded device tests, never the roadmap.
4. One source per fact: docs, READMEs and the site share snippets and version pins.
5. Publication evidence: attribution, licences and stable links are part of the product.

## Accessibility & Inclusion

WCAG 2.2 AA on the landing page and all docs pages: keyboard and visible focus, contrast tested including lilac, 200%
zoom, diagrams with text equivalents and labels that work without colour or motion, `prefers-reduced-motion` respected,
legible code on mobile, static-first rendering, restrained page weight.
