import type { ModelPackage, TaskResult } from "@independo/inderun-contracts";
import { createIndeRunWeb } from "@independo/inderun-web";
import {
  createFixtureOnnxRuntime,
  createTransformersJsRuntime,
  type OnnxTextGenerationRuntime
} from "@independo/inderun-web/onnx";
import {
  getDemoModel,
  getDemoOnnxModelPackageId,
  getDemoOnnxModelRef,
  getDemoProxyEndpointUrl
} from "./config";

const onnxModelRef = getDemoOnnxModelRef();

const onnxModelPackage: ModelPackage = {
  id: getDemoOnnxModelPackageId(),
  format: "onnx",
  tasks: ["text_to_text"],
  runtime: { platforms: ["web"] },
  ...(onnxModelRef !== undefined
    ? { source: { sourceType: "registry", ref: onnxModelRef } }
    : { source: { sourceType: "programmatic" } })
};

// Without VITE_INDERUN_ONNX_MODEL_ID the on-device route runs against the deterministic fixture
// runtime, so reviewers can exercise local_required routing offline and without model downloads.
const onnxRuntime: OnnxTextGenerationRuntime =
  onnxModelRef !== undefined ? createTransformersJsRuntime() : createFixtureOnnxRuntime();

const inderun = createIndeRunWeb({
  openAI: {
    model: getDemoModel(),
    endpointUrl: getDemoProxyEndpointUrl(),
    auth: "none"
  },
  onnx: {
    modelPackage: onnxModelPackage,
    runtime: onnxRuntime
  }
});

export async function runPrompt(
  prompt: string,
  executionMode: "on_device" | "cloud"
): Promise<TaskResult> {
  return inderun.run({
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt,
    constraints:
      executionMode === "on_device" ? { privacy: "local_required" } : { privacy: "cloud_required" }
  });
}

export function getDemoClientConfig(): {
  model: string;
  proxyEndpointUrl: string;
  onDeviceModel: string;
} {
  return {
    model: getDemoModel(),
    proxyEndpointUrl: getDemoProxyEndpointUrl(),
    onDeviceModel: onnxModelRef ?? "deterministic fixture runtime"
  };
}
