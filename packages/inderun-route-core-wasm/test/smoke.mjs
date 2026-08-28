import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { initSharedCore, planRouteJson } from "../dist/index.js";

const wasmBytes = await readFile(
  new URL("../generated/inderun_route_core_bg.wasm", import.meta.url)
);

await initSharedCore(wasmBytes);

const outputJson = await planRouteJson(
  JSON.stringify({
    task: { kind: "text_to_text" },
    constraints: {
      executionTarget: "on_device",
      networkOnline: true
    },
    preferences: {
      preferredProviderIds: []
    },
    providers: [
      {
        descriptor: {
          id: "provider_b",
          type: "local",
          supports: { run: true },
          tasks: ["text_to_text"]
        },
        capabilities: {
          available: true
        }
      },
      {
        descriptor: {
          id: "provider_a",
          type: "local",
          supports: { run: true },
          tasks: ["text_to_text"]
        },
        capabilities: {
          available: true
        }
      }
    ]
  })
);

const plan = JSON.parse(outputJson);
assert.equal(plan.selectedProviderId, "provider_a");
assert.deepEqual(plan.fallbackProviderIds, ["provider_b"]);

// Stream mode must cross the FFI boundary: the planner is expected to drop the
// provider that does not declare streaming and to say why.
const streamOutputJson = await planRouteJson(
  JSON.stringify({
    task: { kind: "text_to_text" },
    interactionMode: "stream",
    constraints: {
      networkOnline: true
    },
    preferences: {},
    providers: [
      {
        descriptor: {
          id: "provider_b",
          type: "local",
          supports: { run: true, streaming: true },
          tasks: ["text_to_text"]
        },
        capabilities: {
          available: true
        }
      },
      {
        descriptor: {
          id: "provider_a",
          type: "local",
          supports: { run: true, streaming: false },
          tasks: ["text_to_text"]
        },
        capabilities: {
          available: true
        }
      }
    ]
  })
);

const streamPlan = JSON.parse(streamOutputJson);
assert.equal(streamPlan.selectedProviderId, "provider_b");
assert.deepEqual(streamPlan.fallbackProviderIds, []);
assert.deepEqual(
  streamPlan.rejectedProviders.map((rejected) => [rejected.providerId, rejected.reasons[0].code]),
  [["provider_a", "streaming_not_supported"]]
);
