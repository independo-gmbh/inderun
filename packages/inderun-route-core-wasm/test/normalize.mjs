import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { registerHooks } from "node:module";

// Records every module the package loads, to prove routing never pulls in the speech module.
const loaded = [];
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context);
    loaded.push(resolved.url);
    return resolved;
  }
});
const speechLoaded = () => loaded.some((url) => url.includes("inderun_speech_text"));

const { initSharedCore, initSpeechText, normalizeSpeechText, planRouteJson } =
  await import("../dist/index.js");
const bytes = (name) => readFile(new URL(`../generated/${name}_bg.wasm`, import.meta.url));

await initSharedCore(await bytes("inderun_route_core"));
const fixture = JSON.parse(
  await readFile(
    new URL("../../../contracts/fixtures/routing/planner-conformance.json", import.meta.url),
    "utf8"
  )
);
const plan = JSON.parse(await planRouteJson(JSON.stringify(fixture.cases[0].input)));
assert.deepEqual(plan, fixture.cases[0].expected);
assert.equal(speechLoaded(), false, "planning must not load the speech module");

await initSpeechText(await bytes("inderun_speech_text"));
assert.equal(speechLoaded(), true);
assert.equal(
  await normalizeSpeechText("Am 3. Mai, z. B. um 14:30 Uhr.", "de-DE"),
  "Am dritten Mai, zum Beispiel um vierzehn Uhr dreißig."
);
assert.equal(await normalizeSpeechText("It is 3 o'clock.", "en-US"), "It is 3 o'clock.");
