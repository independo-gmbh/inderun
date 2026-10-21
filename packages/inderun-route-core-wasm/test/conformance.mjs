import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { initSharedCore, planRouteJson } from "../dist/index.js";

// The shared cross-SDK planner vectors: every input must plan through the WASM build to
// exactly the recorded plan. See contracts/fixtures/routing/planner-conformance.json.
const wasmBytes = await readFile(
  new URL("../generated/inderun_route_core_bg.wasm", import.meta.url)
);
await initSharedCore(wasmBytes);

const fixture = JSON.parse(
  await readFile(
    new URL("../../../contracts/fixtures/routing/planner-conformance.json", import.meta.url),
    "utf8"
  )
);
assert.ok(fixture.cases.length > 0);

for (const { id, input, expected } of fixture.cases) {
  const plan = JSON.parse(await planRouteJson(JSON.stringify(input)));
  assert.deepEqual(plan, expected, `case '${id}'`);
}
