import type { TaskResult } from "@independo/inderun-contracts";
import {
  type IndeRunException,
  type ProviderCapabilitySnapshot,
  toIndeRunException
} from "@independo/inderun-web";
import type { Privacy, RouteDecidedPayload } from "./demo-client";

const DEFAULT_PROMPT =
  "Write a terse status update explaining what IndeRun routed and why it matters.";

const PRIVACY_OPTIONS: Array<{ value: Privacy; label: string }> = [
  { value: "local_required", label: "Local Only" },
  { value: "local_preferred", label: "Prefer Local" },
  { value: "cloud_allowed", label: "Cloud Allowed" },
  { value: "cloud_required", label: "Cloud Only" }
];

const PROVIDER_LABELS: Record<string, string> = {
  openai: "Cloud",
  onnx: "ONNX Local",
  "local.onnx.genai.web": "ONNX Local",
  "local.system-model.web": "Prompt API Local"
};

function providerLabel(snapshot: ProviderCapabilitySnapshot): string {
  return PROVIDER_LABELS[snapshot.providerId] ?? snapshot.descriptor.type;
}

export interface AppDependencies {
  config: {
    model: string;
    proxyEndpointUrl: string;
    /** Model reference backing the on-device ONNX provider, when configured. */
    onDeviceModel?: string;
  };
  runPrompt(prompt: string, privacy: Privacy): Promise<TaskResult>;
  checkProviderCapabilities(): Promise<ProviderCapabilitySnapshot[]>;
  getLastRouteDecision(): RouteDecidedPayload | undefined;
}

type AppState =
  | {
      status: "idle" | "running";
      prompt: string;
      privacy: Privacy;
    }
  | {
      status: "success";
      prompt: string;
      privacy: Privacy;
      result: TaskResult;
    }
  | {
      status: "error";
      prompt: string;
      privacy: Privacy;
      error: IndeRunException;
    };

type CapabilitiesState =
  | { status: "loading" }
  | { status: "ready"; snapshots: ProviderCapabilitySnapshot[] }
  | { status: "error" };

export function mountApp(root: HTMLElement, deps: AppDependencies): void {
  let state: AppState = {
    status: "idle",
    prompt: DEFAULT_PROMPT,
    privacy: "cloud_allowed"
  };
  let capabilitiesState: CapabilitiesState = { status: "loading" };

  const loadCapabilities = async () => {
    try {
      const snapshots = await deps.checkProviderCapabilities();
      capabilitiesState = { status: "ready", snapshots };
    } catch {
      capabilitiesState = { status: "error" };
    }
    render();
  };

  const render = () => {
    const runMetadata = renderRunMetadata(state);
    const outputPanel = renderOutputPanel(state);
    const capabilitiesPanel = renderCapabilitiesPanel(capabilitiesState);
    const routingDecisionPanel = renderRoutingDecision(state, deps.getLastRouteDecision());

    root.innerHTML = `
      <main class="shell">
        <section class="hero">
          <p class="eyebrow">Web Demo</p>
          <h1 class="title">IndeRun Execution Demo</h1>
          <p class="lede">
            Minimal review app for the canonical <code class="code">run()</code> flow on the web:
            preference in, automatic capability-based provider routing, normalized result or error out.
          </p>
          <div class="pill-row">
            <span class="pill">Mode 1</span>
            <span class="pill">Capability Routed</span>
            <span class="pill">Proxy-Backed</span>
          </div>
        </section>

        <section class="panel composer">
          <h2 class="subtitle">Privacy Preference</h2>
          <div class="mode-selector">
            ${PRIVACY_OPTIONS.map(
              (option) =>
                `<button data-privacy="${option.value}" class="preference-btn ${state.privacy === option.value ? "active" : ""}">${option.label}</button>`
            ).join("")}
          </div>

          <label class="label" for="prompt">Prompt</label>
          <textarea id="prompt" name="prompt" rows="8" placeholder="Enter text to send through IndeRun.">${escapeHtml(
            state.prompt
          )}</textarea>
          <div class="actions">
            <button id="run-button" type="button" ${state.status === "running" ? "disabled" : ""}>
              ${state.status === "running" ? "Running..." : "Run"}
            </button>
            <p class="hint">
              Endpoint: <code class="code">${escapeHtml(deps.config.proxyEndpointUrl)}</code> ·
              On-device model: <code class="code">${escapeHtml(deps.config.onDeviceModel ?? "not configured")}</code>
            </p>
          </div>
        </section>

        <section class="panel composer">
          <h2 class="subtitle">Provider Availability</h2>
          ${capabilitiesPanel}
        </section>

        <section class="grid">
          <article class="panel">
            <h2 class="subtitle">Result</h2>
            ${outputPanel}
          </article>

          <article class="panel">
            <h2 class="subtitle">Attempt Metadata</h2>
            ${runMetadata}
          </article>
        </section>

        <section class="panel composer">
          <h2 class="subtitle">Routing Decision</h2>
          ${routingDecisionPanel}
        </section>

        <section class="panel limitations">
          <h2 class="subtitle">Known Limitations</h2>
          <ul>
            <li>On-device ONNX routing uses the Web ONNX Runtime provider. Without <code class="code">VITE_INDERUN_ONNX_MODEL_ID</code> it runs a deterministic fixture runtime instead of real model weights.</li>
            <li>The Prompt API Local provider requires Chrome 138+ on desktop. Its availability badge will show unavailable in other browsers &mdash; this is expected, not a bug.</li>
            <li>The browser never carries production secrets. The standalone demo proxy resolves upstream endpoint and bearer-token configuration server-side.</li>
            <li>The canonical result field is <code class="code">telemetry.totalMs</code>, not <code class="timing">timing.totalMs</code>.</li>
          </ul>
        </section>
      </main>
    `;

    const promptField = root.querySelector<HTMLTextAreaElement>("#prompt");
    const runButton = root.querySelector<HTMLButtonElement>("#run-button");
    const preferenceButtons = root.querySelectorAll<HTMLButtonElement>("[data-privacy]");

    if (!promptField || !runButton || preferenceButtons.length !== PRIVACY_OPTIONS.length) {
      throw new Error("Demo UI failed to render required controls.");
    }

    promptField.addEventListener("input", (event) => {
      const target = event.currentTarget as HTMLTextAreaElement;
      state = { ...state, prompt: target.value };
    });

    preferenceButtons.forEach((button) => {
      button.addEventListener("click", () => {
        const privacy = button.dataset.privacy as Privacy;
        state = { ...state, privacy };
        render();
      });
    });

    runButton.addEventListener("click", async () => {
      const prompt = promptField.value.trim();
      state = { ...state, status: "running", prompt };
      render();

      try {
        const result = await deps.runPrompt(prompt, state.privacy);
        state = {
          ...state,
          status: "success",
          result
        };
      } catch (error) {
        state = {
          ...state,
          status: "error",
          error: toIndeRunException(error)
        };
      }

      await loadCapabilities();
    });
  };

  render();
  void loadCapabilities();
}

function renderOutputPanel(state: AppState): string {
  switch (state.status) {
    case "idle":
      return `<p class="placeholder">Run a prompt to inspect canonical text output or a normalized IndeRun error.</p>`;
    case "running":
      return `<p class="placeholder">Execution in progress. Waiting for provider output...</p>`;
    case "success":
      return `
        <div class="result success">
          <p class="result-label">Generated text</p>
          <pre>${escapeHtml(state.result.output.text)}</pre>
        </div>
      `;
    case "error":
      return `
        <div class="result failure">
          <p class="result-label">Normalized error</p>
          <p><strong class="error-class">${escapeHtml(state.error.errorClass)}</strong></p>
          <pre>${escapeHtml(state.error.message)}</pre>
          ${renderErrorDetails(state.error)}
        </div>
      `;
  }
}

function renderRunMetadata(state: AppState): string {
  if (state.status === "success") {
    return `
      <dl class="meta">
        <div class="meta-item"><dt>Run ID</dt><dd>${escapeHtml(state.result.runId)}</dd></div>
        <div class="meta-item"><dt>Provider Used</dt><dd>${escapeHtml(state.result.telemetry.providerUsed)}</dd></div>
        <div class="meta-item"><dt>Total ms</dt><dd>${formatMs(state.result.telemetry.totalMs)}</dd></div>
        <div class="meta-item"><dt>Finish Reason</dt><dd>${escapeHtml(state.result.finishReason)}</dd></div>
      </dl>
    `;
  }

  if (state.status === "error") {
    return `
      <dl class="meta">
        <div class="meta-item"><dt>Run ID</dt><dd>${escapeHtml(state.error.runId ?? "unavailable")}</dd></div>
        <div class="meta-item"><dt>Provider Used</dt><dd>${escapeHtml(state.error.providerId ?? "unavailable")}</dd></div>
        <div class="meta-item"><dt>Total ms</dt><dd>${formatMs(getErrorTotalMs(state.error.details))}</dd></div>
        <div class="meta-item"><dt>Error Class</dt><dd>${escapeHtml(state.error.errorClass)}</dd></div>
      </dl>
    `;
  }

  return `<p class="placeholder">No attempt yet. Metadata appears after the first run.</p>`;
}

function renderCapabilitiesPanel(state: CapabilitiesState): string {
  if (state.status === "loading") {
    return `<p class="placeholder">Checking provider availability...</p>`;
  }

  if (state.status === "error") {
    return `<p class="placeholder">Unable to check provider availability.</p>`;
  }

  return `
    <div class="badge-row">
      ${state.snapshots
        .map((snapshot) => {
          const available = snapshot.capabilities.available;
          return `
            <div class="badge ${available ? "badge-available" : "badge-unavailable"}">
              <p class="badge-label">${escapeHtml(providerLabel(snapshot))}</p>
              <p class="badge-id">${escapeHtml(snapshot.providerId)}</p>
              <p class="badge-status">${available ? "Available" : "Unavailable"}</p>
              ${!available && snapshot.capabilities.reason ? `<p class="badge-reason">${escapeHtml(snapshot.capabilities.reason)}</p>` : ""}
            </div>
          `;
        })
        .join("")}
    </div>
  `;
}

function renderRoutingDecision(state: AppState, decision: RouteDecidedPayload | undefined): string {
  if (state.status !== "success" && state.status !== "error") {
    return `<p class="placeholder">No run yet. The routing decision appears after the first attempt.</p>`;
  }

  if (!decision) {
    return `<p class="placeholder">No routing decision was captured for the last attempt.</p>`;
  }

  const rejected = decision.rejectedProviders
    .map(
      (rejection) => `
        <div class="rejection">
          <p class="rejection-provider">${escapeHtml(rejection.providerId)}</p>
          <ul>
            ${rejection.reasons.map((reason) => `<li>${escapeHtml(reason.code)}: ${escapeHtml(reason.message)}</li>`).join("")}
          </ul>
        </div>
      `
    )
    .join("");

  return `
    <dl class="meta">
      <div class="meta-item"><dt>Selected Provider</dt><dd>${escapeHtml(decision.selectedProviderId ?? "none")}</dd></div>
      <div class="meta-item"><dt>Explanation</dt><dd>${escapeHtml(decision.explanation.summary)}</dd></div>
    </dl>
    ${rejected ? `<p class="result-label">Rejected Providers</p>${rejected}` : ""}
  `;
}

function getErrorTotalMs(details: Record<string, unknown> | undefined): number | undefined {
  const value = details?.totalMs;
  return typeof value === "number" ? value : undefined;
}

function formatMs(value: number | undefined): string {
  return typeof value === "number" ? `${value.toFixed(0)} ms` : "unavailable";
}

function renderErrorDetails(error: IndeRunException): string {
  const originalError = error.details?.originalError;
  if (!isRecord(originalError)) {
    return "";
  }

  const name = typeof originalError.name === "string" ? originalError.name : "Error";
  const message = typeof originalError.message === "string" ? originalError.message : "";
  if (!message) {
    return "";
  }

  return `
    <p class="result-label">Fetch detail</p>
    <pre class="code">${escapeHtml(`${name}: ${message}`)}</pre>
  `;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
