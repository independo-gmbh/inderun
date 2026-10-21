import type {
  ExecutionProvenance,
  IndeRunException,
  ProviderCapabilitySnapshot
} from "@independo/inderun-web";
import { isOnDeviceTarget, ONNX_TARGET_ID, type Privacy, SYSTEM_MODEL_TARGET_ID } from "./simplify";

/**
 * Renders what a simplification run reports about itself. Everything here reads
 * `ExecutionProvenance` (or the capability snapshot, for the pre-run status), never
 * telemetry or `providerUsed`, and never states more than those records say.
 */

export type Delivery = "whole" | "stream";

export interface TargetCatalog {
  /** The demo's cloud target id, `openai:<model>`. */
  cloudTargetId: string;
  /** True when the ONNX target runs the deterministic fixture runtime, not real weights. */
  onDeviceFixture: boolean;
}

type RejectionCode = ExecutionProvenance["routeRejections"][number]["codes"][number];

const LOCALITY_TEXT: Record<ExecutionProvenance["locality"], string> = {
  on_device: "On this device",
  edge: "Edge",
  cloud: "Cloud",
  unknown: "Unknown"
};

const REJECTION_TEXT: Record<RejectionCode, string> = {
  task_not_supported: "cannot do this task",
  run_not_supported: "cannot return a whole result",
  streaming_not_supported: "cannot stream",
  streaming_unavailable: "cannot stream here right now",
  privacy_constraint: "excluded by the privacy choice",
  cloud_constraint: "excluded by the cloud setting",
  offline: "needs a network connection",
  capability_unavailable: "not available in this browser or device",
  not_in_model_profile: "not part of this model profile"
};

const STREAMING_CODES: readonly RejectionCode[] = [
  "streaming_not_supported",
  "streaming_unavailable"
];

export function targetLabel(targetId: string, catalog: TargetCatalog): string {
  if (targetId === SYSTEM_MODEL_TARGET_ID) {
    return "Browser built-in model (Prompt API)";
  }
  if (targetId === ONNX_TARGET_ID) {
    return catalog.onDeviceFixture
      ? "ONNX in the browser (fixture runtime)"
      : "ONNX model in the browser";
  }
  if (targetId === catalog.cloudTargetId) {
    return "Cloud model via the demo proxy";
  }
  return targetId;
}

function targetName(targetId: string, catalog: TargetCatalog): string {
  return `${escapeHtml(targetLabel(targetId, catalog))} <code class="code">${escapeHtml(targetId)}</code>`;
}

/** The provenance panel for one run's outcome. */
export function renderProvenance(
  provenance: ExecutionProvenance | undefined,
  catalog: TargetCatalog
): string {
  if (!provenance) {
    return `<p class="placeholder">This outcome carried no execution provenance, so the demo does not say where it ran.</p>`;
  }

  const target = provenance.providerId
    ? targetName(provenance.providerId, catalog)
    : "None &mdash; no target produced or was committed to this outcome";
  const fallback = provenance.fallbackOccurred
    ? `Yes &mdash; ${provenance.attemptCount} targets attempted`
    : provenance.attemptCount === 0
      ? "No &mdash; no target was attempted"
      : "No &mdash; 1 target attempted";

  const attempts =
    provenance.attempts.length === 0
      ? `<li class="placeholder">None.</li>`
      : provenance.attempts
          .map(
            (attempt) =>
              `<li>${targetName(attempt.providerId, catalog)} &mdash; <span class="outcome outcome-${escapeHtml(attempt.outcome)}">${escapeHtml(attempt.outcome)}</span>${attempt.errorClass ? ` (${escapeHtml(attempt.errorClass)})` : ""}</li>`
          )
          .join("");

  const rejections =
    provenance.routeRejections.length === 0
      ? `<li class="placeholder">None.</li>`
      : provenance.routeRejections
          .map(
            (rejection) =>
              `<li>${targetName(rejection.providerId, catalog)}: ${rejection.codes
                .map(
                  (code) =>
                    `${escapeHtml(REJECTION_TEXT[code] ?? code)} <code class="code">${escapeHtml(code)}</code>`
                )
                .join(", ")}</li>`
          )
          .join("");

  return `
    <dl class="meta provenance">
      <div class="meta-item"><dt>Where it ran</dt><dd>${escapeHtml(LOCALITY_TEXT[provenance.locality] ?? provenance.locality)}</dd></div>
      <div class="meta-item"><dt>Target</dt><dd>${target}</dd></div>
      <div class="meta-item"><dt>Model profile</dt><dd><code class="code">${escapeHtml(provenance.modelProfile)}</code></dd></div>
      <div class="meta-item"><dt>Configured model</dt><dd>${provenance.configuredModel ? escapeHtml(provenance.configuredModel) : "not declared"}</dd></div>
      <div class="meta-item"><dt>Reported model</dt><dd>${provenance.reportedModel ? escapeHtml(provenance.reportedModel) : "not reported"}</dd></div>
      <div class="meta-item"><dt>Fallback</dt><dd>${fallback}</dd></div>
    </dl>
    <p class="result-label">Attempts, in order</p>
    <ol class="provenance-list">${attempts}</ol>
    <p class="result-label">Skipped by routing</p>
    <ul class="provenance-list">${rejections}</ul>
    <p class="hint">Locality is what the target declares, not a measurement. A model the provider did not report is shown as not reported, never guessed.</p>
  `;
}

export interface Notice {
  tone: "warn" | "info";
  title: string;
  body: string;
}

export interface NoticeContext {
  privacy: Privacy;
  delivery: Delivery;
  online: boolean;
  provenance?: ExecutionProvenance;
  error?: IndeRunException;
  catalog: TargetCatalog;
}

/**
 * The honest states that apply to one outcome. Each is derived from the provenance, the
 * error class, or the browser's own connectivity flag; none is inferred from configuration.
 */
export function outcomeNotices(context: NoticeContext): Notice[] {
  const { provenance, error, catalog } = context;
  const rejections = provenance?.routeRejections ?? [];
  const attempts = provenance?.attempts ?? [];
  const rejectedWith = (predicate: (id: string) => boolean, codes: readonly RejectionCode[]) =>
    rejections.some(
      (rejection) =>
        predicate(rejection.providerId) && rejection.codes.some((code) => codes.includes(code))
    );
  const notices: Notice[] = [];

  const offline =
    !context.online ||
    error?.errorClass === "Offline" ||
    rejectedWith(() => true, ["offline"]) ||
    attempts.some((attempt) => attempt.errorClass === "Offline");
  if (offline) {
    notices.push({
      tone: "warn",
      title: "Offline: the cloud is unavailable",
      body: "This device has no network connection, so the cloud target cannot run. Only an on-device target can, if one is available here."
    });
  }

  const localSkippedForStreaming =
    context.delivery === "stream" && rejectedWith(isOnDeviceTarget, STREAMING_CODES);
  if (localSkippedForStreaming) {
    notices.push({
      tone: "info",
      title: "On-device targets cannot stream yet",
      body: "On the web, neither on-device target streams, so routing skipped them for streamText(). Choose “Whole result” to run on this device."
    });
  }

  if (error && context.privacy === "local_required" && !localSkippedForStreaming) {
    notices.push({
      tone: "warn",
      title: "No on-device model could run this",
      body: "None of the on-device targets could run here (see the attempts and skipped targets below), and “On this device only” does not allow the cloud. Choose “Prefer this device” or “Cloud allowed” if sending this text to the cloud is acceptable."
    });
  }

  if (rejectedWith((id) => !isOnDeviceTarget(id), ["privacy_constraint", "cloud_constraint"])) {
    notices.push({
      tone: "info",
      title: "Cloud not permitted",
      body: "The cloud target was skipped because the privacy choice keeps this text on the device."
    });
  }

  const promptApiMissing =
    rejectedWith((id) => id === SYSTEM_MODEL_TARGET_ID, ["capability_unavailable"]) ||
    attempts.some(
      (attempt) =>
        attempt.providerId === SYSTEM_MODEL_TARGET_ID && attempt.errorClass === "CapabilityMismatch"
    );
  if (promptApiMissing) {
    notices.push({
      tone: "info",
      title: "Browser built-in model not available",
      body: "The Prompt API is not usable in this browser, so that target did not run. It needs desktop Chrome 138 or later and may need to download its model first; other browsers fall through to the next target."
    });
  }

  if (provenance?.providerId === ONNX_TARGET_ID && catalog.onDeviceFixture) {
    notices.push({
      tone: "warn",
      title: "Fixture output, not a real model",
      body: "This ran on the ONNX target's deterministic fixture runtime, which echoes its input instead of simplifying it. Set VITE_INDERUN_ONNX_MODEL_ID to run real model weights."
    });
  }

  if (provenance?.fallbackOccurred && provenance.providerId) {
    const failed = attempts.filter((attempt) => attempt.outcome === "failed");
    const reasons = failed
      .map(
        (attempt) =>
          `${targetLabel(attempt.providerId, catalog)}${attempt.errorClass ? ` (${attempt.errorClass})` : ""}`
      )
      .join(", ");
    notices.push({
      tone: "info",
      title: "Fell back to another target",
      body: `${reasons || "An earlier target"} failed, so IndeRun moved on to ${targetLabel(provenance.providerId, catalog)}, which the privacy choice permits.`
    });
  }

  if (
    !error &&
    context.privacy === "local_preferred" &&
    provenance?.locality === "cloud" &&
    !provenance.fallbackOccurred
  ) {
    notices.push({
      tone: "info",
      title: "Sent to the cloud",
      body: "“Prefer this device” allows the cloud when no on-device target can take the request. The skipped targets below say why none did."
    });
  }

  return notices;
}

export function renderNotices(notices: Notice[]): string {
  if (notices.length === 0) {
    return "";
  }
  return `
    <ul class="notices">
      ${notices
        .map(
          (notice) =>
            `<li class="notice notice-${notice.tone}"><strong>${escapeHtml(notice.title)}.</strong> ${escapeHtml(notice.body)}</li>`
        )
        .join("")}
    </ul>
  `;
}

/**
 * What `checkCapabilities()` says about the profile's targets before anything runs. A run can
 * still differ; its provenance is the record of what actually happened.
 */
export function renderDeviceStatus(
  snapshots: ProviderCapabilitySnapshot[] | undefined,
  profileTargets: string[],
  online: boolean,
  catalog: TargetCatalog
): string {
  const network = online
    ? `<li class="status-item status-ok">Network: online</li>`
    : `<li class="status-item status-bad">Network: offline &mdash; the cloud target cannot run</li>`;

  if (!snapshots) {
    return `<ul class="status-list">${network}<li class="status-item placeholder">Checking which targets are available&hellip;</li></ul>`;
  }

  const items = profileTargets.map((targetId) => {
    const snapshot = snapshots.find((candidate) => candidate.providerId === targetId);
    if (!snapshot) {
      return `<li class="status-item status-bad">${targetName(targetId, catalog)}: not registered</li>`;
    }
    const available = snapshot.capabilities.available;
    const reason =
      !available && snapshot.capabilities.reason
        ? ` &mdash; ${escapeHtml(snapshot.capabilities.reason)}`
        : "";
    const fixture =
      available && targetId === ONNX_TARGET_ID && catalog.onDeviceFixture
        ? " &mdash; echoes input; not a real model"
        : "";
    return `<li class="status-item ${available ? "status-ok" : "status-bad"}">${targetName(targetId, catalog)}: ${available ? "available" : "unavailable"}${reason}${fixture}</li>`;
  });

  return `<ul class="status-list">${network}${items.join("")}</ul>`;
}

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
