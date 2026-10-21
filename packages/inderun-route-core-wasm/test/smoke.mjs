import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { initSharedCore, planRouteJson } from "../dist/index.js";

const wasmBytes = await readFile(
  new URL("../generated/inderun_route_core_bg.wasm", import.meta.url)
);

await initSharedCore(wasmBytes);

// The planner reads the full provider-descriptor contract; only the fields under test vary.
function localDescriptor(id, { streaming = false } = {}) {
  return {
    id,
    type: "local",
    transport: "in_process",
    supports: {
      run: true,
      streaming,
      realtime: false,
      tools: false,
      reasoningEvents: false,
      structuredOutput: false,
      multimodal: false
    },
    cancel: "soft",
    tasks: ["text_to_text"]
  };
}

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
        descriptor: localDescriptor("provider_b"),
        capabilities: {
          available: true
        }
      },
      {
        descriptor: localDescriptor("provider_a"),
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
        descriptor: localDescriptor("provider_b", { streaming: true }),
        capabilities: {
          available: true
        }
      },
      {
        descriptor: localDescriptor("provider_a", { streaming: false }),
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
