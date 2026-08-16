import type {
  ModelPackage,
  TaskRequest,
  TaskResult,
  TelemetryEvent
} from "@independo/inderun-contracts";
import { createIndeRunWeb, type ProviderCapabilitySnapshot } from "@independo/inderun-web";
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

/**
 * `Privacy` isn't re-exported from `@independo/inderun-contracts` on its own (only top-level
 * schema types are), so it's derived here from the canonical `TaskRequest` contract type.
 */
export type Privacy = NonNullable<NonNullable<TaskRequest["constraints"]>["privacy"]>;

/**
 * Narrow view of the `route_decided` telemetry event payload this demo reads.
 * The contract-level `TelemetryEvent.payload` is untyped, so fields are read defensively.
 */
export interface RouteDecidedPayload {
  selectedProviderId: string | null;
  fallbackProviderIds: string[];
  rejectedProviders: Array<{
    providerId: string;
    reasons: Array<{ code: string; message: string }>;
  }>;
  explanation: { summary: string };
  constraints: Record<string, unknown> | null;
  preferences: Record<string, unknown> | null;
  plannerSource: string | null;
  plannerUnavailableReason: string | null;
}

function toRouteDecidedPayload(payload: Record<string, unknown>): RouteDecidedPayload | undefined {
  if (typeof payload !== "object" || payload === null) {
    return undefined;
  }

  const rejectedProviders = Array.isArray(payload.rejectedProviders)
    ? (payload.rejectedProviders as RouteDecidedPayload["rejectedProviders"])
    : [];
  const explanation =
    typeof payload.explanation === "object" && payload.explanation !== null
      ? (payload.explanation as { summary: string })
      : { summary: "" };

  return {
    selectedProviderId:
      typeof payload.selectedProviderId === "string" ? payload.selectedProviderId : null,
    fallbackProviderIds: Array.isArray(payload.fallbackProviderIds)
      ? (payload.fallbackProviderIds as string[])
      : [],
    rejectedProviders,
    explanation,
    constraints: (payload.constraints as Record<string, unknown> | null) ?? null,
    preferences: (payload.preferences as Record<string, unknown> | null) ?? null,
    plannerSource: typeof payload.plannerSource === "string" ? payload.plannerSource : null,
    plannerUnavailableReason:
      typeof payload.plannerUnavailableReason === "string" ? payload.plannerUnavailableReason : null
  };
}

class RouteDecisionTelemetryService {
  private lastRouteDecision: RouteDecidedPayload | undefined;

  emit(event: TelemetryEvent): void {
    if (event.type !== "route_decided") {
      return;
    }

    this.lastRouteDecision = toRouteDecidedPayload(event.payload as Record<string, unknown>);
  }

  getLastRouteDecision(): RouteDecidedPayload | undefined {
    return this.lastRouteDecision;
  }
}

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

const routeDecisionTelemetry = new RouteDecisionTelemetryService();

const inderun = createIndeRunWeb({
  openAI: {
    model: getDemoModel(),
    endpointUrl: getDemoProxyEndpointUrl(),
    auth: "none"
  },
  onnx: {
    modelPackage: onnxModelPackage,
    runtime: onnxRuntime
  },
  systemModel: {},
  hostServices: { telemetry: routeDecisionTelemetry }
});

export async function runPrompt(prompt: string, privacy: Privacy): Promise<TaskResult> {
  return inderun.run({
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt,
    constraints: { privacy }
  });
}

export function checkProviderCapabilities(): Promise<ProviderCapabilitySnapshot[]> {
  return inderun.checkCapabilities();
}

export function getLastRouteDecision(): RouteDecidedPayload | undefined {
  return routeDecisionTelemetry.getLastRouteDecision();
}

export function getDemoClientConfig(): {
  model: string;
  proxyEndpointUrl: string;
  onDeviceModel: string;
  systemModelHint: string;
} {
  return {
    model: getDemoModel(),
    proxyEndpointUrl: getDemoProxyEndpointUrl(),
    onDeviceModel: onnxModelRef ?? "deterministic fixture runtime",
    systemModelHint: "Prompt API needs no configured model — the browser owns download/availability"
  };
}
