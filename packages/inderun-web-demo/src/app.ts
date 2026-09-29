import type { StreamEvent, TaskResult } from "@independo/inderun-contracts";
import {
  type IndeRunException,
  type ProviderCapabilitySnapshot,
  type StreamRun,
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
  streamPrompt(prompt: string, privacy: Privacy): Promise<StreamRun>;
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

/** One line per canonical event, so ordering and gaps are visible on screen. */
interface StreamLogEntry {
  sequence: number;
  type: string;
  detail: string;
}

type StreamState =
  | { status: "idle" }
  | {
      status: "streaming";
      text: string;
      log: StreamLogEntry[];
      cancel: (reason?: string) => void;
    }
  | { status: "ended"; text: string; log: StreamLogEntry[]; summary: string }
  /** The `stream()` call itself was refused, so there is no run and no events. */
  | { status: "rejected"; error: IndeRunException };

export function mountApp(root: HTMLElement, deps: AppDependencies): void {
  let state: AppState = {
    status: "idle",
    prompt: DEFAULT_PROMPT,
    privacy: "cloud_allowed"
  };
  let capabilitiesState: CapabilitiesState = { status: "loading" };
  let streamState: StreamState = { status: "idle" };

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
    const streaming = streamState.status === "streaming";

    root.innerHTML = `
      <main class="shell">
        <section class="hero">
          <p class="eyebrow">Web Demo</p>
          <h1 class="title">IndeRun Execution Demo</h1>
          <p class="lede">
            Minimal review app for the canonical <code class="code">run()</code> and
            <code class="code">stream()</code> flows on the web: preference in, automatic
            capability-based provider routing, normalized result or error out.
          </p>
          <div class="pill-row">
            <span class="pill">Mode 1</span>
            <span class="pill">Mode 2</span>
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
            <button id="run-button" type="button" ${state.status === "running" || streaming ? "disabled" : ""}>
              ${state.status === "running" ? "Running..." : "Run"}
            </button>
            <button id="stream-button" type="button" ${state.status === "running" ? "disabled" : ""}>
              ${streaming ? "Cancel" : "Stream"}
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
          <h2 class="subtitle">Streaming (Mode 2)</h2>
          ${renderStreamPanel(streamState)}
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
    const streamButton = root.querySelector<HTMLButtonElement>("#stream-button");
    const preferenceButtons = root.querySelectorAll<HTMLButtonElement>("[data-privacy]");

    if (
      !promptField ||
      !runButton ||
      !streamButton ||
      preferenceButtons.length !== PRIVACY_OPTIONS.length
    ) {
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

    streamButton.addEventListener("click", async () => {
      if (streamState.status === "streaming") {
        streamState.cancel("user cancelled");
        return;
      }

      const prompt = promptField.value.trim();
      state = { ...state, prompt };

      let run: StreamRun;
      try {
        run = await deps.streamPrompt(prompt, state.privacy);
      } catch (error) {
        // A routing refusal rejects the stream() call itself: no handle, no events.
        streamState = { status: "rejected", error: toIndeRunException(error) };
        render();
        return;
      }

      const live = { text: "", log: [] as StreamLogEntry[] };
      streamState = {
        status: "streaming",
        text: live.text,
        log: live.log,
        cancel: (reason) => run.cancel(reason)
      };
      render();

      // Patch the two stream elements in place rather than re-rendering the whole
      // app per event, so a delta does not steal focus from the prompt field.
      const output = root.querySelector<HTMLElement>("#stream-output");
      const log = root.querySelector<HTMLElement>("#stream-log");

      let summary = "The provider stream ended without a terminal event.";
      try {
        for await (const event of run.events) {
          live.text = applyStreamEvent(event, live.text);
          live.log.push(streamLogEntry(event));
          if (event.type === "terminal") {
            summary = terminalSummary(event);
          }
          if (output) output.textContent = live.text;
          if (log) log.innerHTML = renderStreamLog(live.log);
        }
      } catch (error) {
        // A transport failure, as opposed to a terminal `error` outcome, which is
        // a normal event and completes the iteration.
        summary = `Transport failure: ${toIndeRunException(error).errorClass}`;
      }

      streamState = { status: "ended", text: live.text, log: live.log, summary };
      render();
    });
  };

  render();
  void loadCapabilities();
}

/**
 * Deltas append; a snapshot replaces the run's cumulative text, so an empty one
 * visibly retracts what was already on screen.
 */
function applyStreamEvent(event: StreamEvent, text: string): string {
  const payload = event.payload as { text?: string } | undefined;
  if (event.type === "content_delta") {
    return text + (payload?.text ?? "");
  }
  if (event.type === "content_snapshot") {
    return payload?.text ?? "";
  }
  return text;
}

function terminalSummary(event: StreamEvent): string {
  const payload = event.payload as
    { outcome?: string; finishReason?: string; error?: { errorClass?: string } } | undefined;
  switch (payload?.outcome) {
    case "completed":
      return `Completed${payload.finishReason ? ` (${payload.finishReason})` : ""}.`;
    case "cancelled":
      return "Cancelled. The text above is what had been delivered when the cancel landed.";
    case "error":
      return `Terminal error outcome: ${payload.error?.errorClass ?? "unknown"}. This is an event, not a rejection.`;
    default:
      return "Unrecognized terminal outcome.";
  }
}

function streamLogEntry(event: StreamEvent): StreamLogEntry {
  const payload = event.payload as { text?: string; outcome?: string; phase?: string } | undefined;
  let detail = "";
  if (event.type === "content_delta") {
    detail = `+${JSON.stringify(payload?.text ?? "")}`;
  } else if (event.type === "content_snapshot") {
    detail = `=${JSON.stringify(payload?.text ?? "")}`;
  } else if (event.type === "terminal") {
    detail = payload?.outcome ?? "";
  } else if (payload?.phase !== undefined) {
    detail = payload.phase;
  }
  return { sequence: event.sequence, type: event.type, detail };
}

function renderStreamLog(entries: StreamLogEntry[]): string {
  if (entries.length === 0) {
    return `<li class="placeholder">No events yet.</li>`;
  }
  return entries
    .map(
      (entry) =>
        `<li><code class="code">${entry.sequence}</code> ${escapeHtml(entry.type)} ${escapeHtml(entry.detail)}</li>`
    )
    .join("");
}

function renderStreamPanel(streamState: StreamState): string {
  if (streamState.status === "idle") {
    return `<p class="placeholder">Press Stream to run the same prompt through <code class="code">stream()</code>. Events are ordered by <code class="code">sequence</code>, not arrival.</p>`;
  }
  if (streamState.status === "rejected") {
    return `
      <div class="result failure">
        <p class="result-label">stream() rejected</p>
        <p><strong class="error-class">${escapeHtml(streamState.error.errorClass)}</strong></p>
        <p>${escapeHtml(streamState.error.message)}</p>
        <p class="hint">A routing refusal rejects the call itself &mdash; there is no run handle and no events.</p>
      </div>
    `;
  }

  const summary =
    streamState.status === "ended"
      ? `<p class="hint">${escapeHtml(streamState.summary)}</p>`
      : `<p class="hint">Streaming. Press Cancel to stop.</p>`;

  return `
    <div class="result ${streamState.status === "ended" ? "success" : ""}">
      <p class="result-label">Streamed text</p>
      <pre id="stream-output">${escapeHtml(streamState.text)}</pre>
      ${summary}
      <p class="result-label">Event log</p>
      <ul id="stream-log">${renderStreamLog(streamState.log)}</ul>
    </div>
  `;
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
