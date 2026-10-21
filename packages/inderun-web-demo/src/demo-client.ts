import { createIndeRunWeb, type IndeRunApi } from "@independo/inderun-web";
import {
  createFixtureOnnxRuntime,
  createTransformersJsRuntime,
  type ModelPackage,
  type OnnxTextGenerationRuntime
} from "@independo/inderun-web/onnx";
import {
  getDemoModel,
  getDemoOnnxModelPackageId,
  getDemoOnnxModelRef,
  getDemoProxyEndpointUrl
} from "./config";
import { RouteDecisionTelemetryService, type RouteDecidedPayload } from "./route-decision";
import { SIMPLIFY_PROFILE, simplifyProfileTargets } from "./simplify";

const cloudModel = getDemoModel();
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
// The UI labels that output as a fixture wherever it appears.
const onnxRuntime: OnnxTextGenerationRuntime =
  onnxModelRef !== undefined ? createTransformersJsRuntime() : createFixtureOnnxRuntime();

const routeDecisionTelemetry = new RouteDecisionTelemetryService();

/**
 * One engine for the whole demo. The `simplify` profile names the three targets the
 * simplification feature may use, in preference order; the advanced panels send requests
 * without a profile, so they route across every registered target (`"auto"`).
 */
export const inderun: IndeRunApi = createIndeRunWeb({
  openAI: {
    models: [cloudModel],
    endpointUrl: getDemoProxyEndpointUrl(),
    auth: "none"
  },
  onnx: {
    modelPackage: onnxModelPackage,
    runtime: onnxRuntime
  },
  systemModel: {},
  modelProfiles: { [SIMPLIFY_PROFILE]: simplifyProfileTargets(cloudModel) },
  hostServices: { telemetry: routeDecisionTelemetry }
});

export function getLastRouteDecision(): RouteDecidedPayload | undefined {
  return routeDecisionTelemetry.getLastRouteDecision();
}

export function getDemoClientConfig(): {
  cloudModel: string;
  proxyEndpointUrl: string;
  onDeviceModel?: string;
} {
  return {
    cloudModel,
    proxyEndpointUrl: getDemoProxyEndpointUrl(),
    ...(onnxModelRef !== undefined ? { onDeviceModel: onnxModelRef } : {})
  };
}
