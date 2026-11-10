#!/usr/bin/env node
/**
 * Renders the social preview image, public/og/default.jpg (1200×630), from HTML in a headless
 * Chromium. Run it after changing the hero copy, the logo or the engine list below, and commit the
 * JPEG; the build never runs this script.
 *
 * The image is the landing's black panel on the paper ground: the IndeRun logo
 * (src/assets/brand/inderun-logo.svg, letters in off-white), the hero headline and support line,
 * and one plate per on-device engine with its monochrome Simple Icons mark. Keep the copy in step
 * with src/pages/index.astro and the og:image:alt text in src/components/seo/Metadata.astro and
 * astro.config.mjs.
 *
 *   pnpm --filter website exec playwright install chromium-headless-shell   # once
 *   pnpm --filter website render:og
 *
 * Pass an output path to render somewhere else. The script fails if the engine plates overflow
 * the panel.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { siApple, siGooglechrome, siGooglegemini, siOnnx } from "simple-icons";

const root = new URL("../", import.meta.url);
const out = process.argv[2] ?? fileURLToPath(new URL("public/og/default.jpg", root));

const font = readFileSync(new URL("src/assets/fonts/InterVariable.woff2", root)).toString("base64");
const logo = readFileSync(new URL("src/assets/brand/inderun-logo.svg", root), "utf8").replace(
  "<svg ",
  '<svg class="logo" '
);

const headline = "On-device AI for the devices your users actually have.";
const support = "On-device when available. Cloud only when you allow it.";
const engines = [
  [siApple, "Apple Foundation Models"],
  [siGooglegemini, "Gemini Nano"],
  [siGooglechrome, "Chrome built-in AI"],
  [siOnnx, "ONNX Runtime"]
];

const plate = ([icon, name]) =>
  `<li><svg viewBox="0 0 24 24" aria-hidden="true"><path d="${icon.path}"/></svg><span>${name}</span></li>`;

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
@font-face{font-family:Inter;src:url(data:font/woff2;base64,${font}) format("woff2");font-weight:100 900}
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:1200px;height:630px;background:#faf5ef;font-family:Inter,sans-serif}
.panel{position:absolute;inset:40px;background:#000;border-radius:4px;box-shadow:inset 0 0 0 1px #3a3835;color:#faf5ef;padding:56px 64px;display:flex;flex-direction:column}
.top{display:flex;justify-content:space-between;align-items:center}
.logo{width:330px;height:auto;display:block;color:#faf5ef}
.url{font-size:24px;font-weight:500;color:#bdb7af}
h1{margin-top:52px;font-size:60px;line-height:1.04;font-weight:750;letter-spacing:-0.035em;max-width:900px}
p{margin-top:18px;font-size:28px;line-height:1.3;color:#bdb7af;font-weight:500}
ul{margin-top:auto;list-style:none;display:flex;gap:10px}
li{display:flex;flex:1 1 auto;justify-content:center;align-items:center;gap:10px;padding:14px;border:1px solid #3a3835;border-radius:3px;background:#121212;font-size:20px;font-weight:600;white-space:nowrap}
li svg{width:24px;height:24px;fill:#faf5ef;flex:none}
</style></head><body><div class="panel">
<div class="top">${logo}<span class="url">inderun.dev</span></div>
<h1>${headline}</h1>
<p>${support}</p>
<ul>${engines.map(plate).join("")}</ul>
</div></body></html>`;

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
  await page.setContent(html, { waitUntil: "load" });
  await page.evaluate(() => document.fonts.ready);
  const overflow = await page.evaluate(() => {
    const last = document.querySelector("li:last-child").getBoundingClientRect();
    const panel = document.querySelector(".panel").getBoundingClientRect();
    return Math.round(last.right - (panel.right - 64));
  });
  if (overflow > 0) throw new Error(`The engine plates overflow the panel by ${overflow}px.`);
  await page.screenshot({ path: out, type: "jpeg", quality: 90 });
  console.log(`render-og-image: wrote ${out}`);
} finally {
  await browser.close();
}
