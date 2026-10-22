import {
  type ExecutionProvenance,
  generateText,
  type IndeRunApi,
  type IndeRunException,
  type ProviderCapabilitySnapshot,
  type StreamEvent,
  type StreamRun,
  streamText,
  type TaskRequest,
  type TaskResult,
  type TextStream,
  toIndeRunException
} from "@independo/inderun-web";
import type { RouteDecidedPayload } from "./route-decision";
import {
  type Delivery,
  escapeHtml,
  outcomeNotices,
  renderDeviceStatus,
  renderNotices,
  renderProvenance,
  type TargetCatalog
} from "./provenance-view";
import {
  cloudTargetId,
  type Privacy,
  SAMPLE_TEXT,
  SIMPLIFY_PROFILE,
  simplifyOptions,
  simplifyProfileTargets
} from "./simplify";

const SIMPLIFY_PRIVACY_OPTIONS: Array<{ value: Privacy; label: string; hint: string }> = [
  {
    value: "local_required",
    label: "On this device only",
    hint: "The text never leaves this device. If no on-device model can run here, nothing runs."
  },
  {
    value: "local_preferred",
    label: "Prefer this device",
    hint: "On-device targets are tried first, but the text may be sent to the cloud when none of them can run it."
  },
  {
    value: "cloud_allowed",
    label: "Cloud allowed",
    hint: "Any target in the profile may run it, the cloud included."
  }
];

const DELIVERY_OPTIONS: Array<{ value: Delivery; label: string; hint: string }> = [
  {
    value: "whole",
    label: "Whole result",
    hint: "generateText(): every target can run it, on-device ones included. It cannot be stopped once started."
  },
  {
    value: "stream",
    label: "Stream",
    hint: "streamText(): text appears as it arrives and Stop works. On the web only the cloud target streams today, so on-device targets are skipped."
  }
];

/** Advanced panel: the raw canonical privacy values, `cloud_required` included. */
const PRIVACY_OPTIONS: Array<{ value: Privacy; label: string }> = [
  { value: "local_required", label: "Local Only" },
  { value: "local_preferred", label: "Prefer Local" },
  { value: "cloud_allowed", label: "Cloud Allowed" },
  { value: "cloud_required", label: "Cloud Only" }
];

const DEFAULT_PROMPT =
  "Write a terse status update explaining what IndeRun routed and why it matters.";

const PROVIDER_LABELS: Record<string, string> = {
  openai: "Cloud",
  onnx: "ONNX Local",
  "local.onnx.genai.web": "ONNX Local",
  "local.system-model.web": "Prompt API Local"
};

function providerLabel(snapshot: ProviderCapabilitySnapshot): string {
  // Factory-registered OpenAI targets are named `<id>:<model>`; label them by provider.
  const providerKey = snapshot.providerId.split(":")[0] ?? snapshot.providerId;
  return PROVIDER_LABELS[providerKey] ?? snapshot.descriptor.type;
}

export interface AppConfig {
  /** Cloud model the browser registers as the `openai:<model>` target. */
  cloudModel: string;
  proxyEndpointUrl: string;
  /** Model reference backing the on-device ONNX target; absent when it runs the fixture runtime. */
  onDeviceModel?: string;
}

export interface AppDependencies {
  inderun: IndeRunApi;
  config: AppConfig;
  /** Last `route_decided` telemetry payload, for the advanced routing panel only. */
  getLastRouteDecision(): RouteDecidedPayload | undefined;
  /** Defaults to `navigator.onLine`. */
  isOnline?(): boolean;
}

type SimplifyRun = { privacy: Privacy; delivery: Delivery };

type SimplifyState =
  | { status: "idle" }
  | (SimplifyRun & {
      status: "running";
      /** Text delivered so far; mutated in place while a stream runs. */
      text: string;
      /** Present once `streamText()` has returned a run to cancel. */
      cancel?: (reason?: string) => void;
    })
  | (SimplifyRun & {
      status: "done";
      text: string;
      stopped: boolean;
      provenance?: ExecutionProvenance;
    })
  | (SimplifyRun & { status: "failed"; text: string; error: IndeRunException });

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
      routeDecision?: RouteDecidedPayload;
    }
  | {
      status: "error";
      prompt: string;
      privacy: Privacy;
      error: IndeRunException;
      routeDecision?: RouteDecidedPayload;
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

function taskRequest(prompt: string, privacy: Privacy): TaskRequest {
  return {
    schemaVersion: "1.0",
    task: { kind: "text_to_text" },
    prompt,
    constraints: { privacy }
  };
}

export function mountApp(root: HTMLElement, deps: AppDependencies): void {
  const isOnline = deps.isOnline ?? (() => navigator.onLine);
  const catalog: TargetCatalog = {
    cloudTargetId: cloudTargetId(deps.config.cloudModel),
    onDeviceFixture: deps.config.onDeviceModel === undefined
  };
  const profileTargets = simplifyProfileTargets(deps.config.cloudModel);

  const ui = {
    simplifyText: SAMPLE_TEXT,
    privacy: "local_preferred" as Privacy,
    delivery: "whole" as Delivery,
    advancedOpen: false
  };
  let simplify: SimplifyState = { status: "idle" };
  let state: AppState = {
    status: "idle",
    prompt: DEFAULT_PROMPT,
    privacy: "cloud_allowed"
  };
  let capabilitiesState: CapabilitiesState = { status: "loading" };
  let streamState: StreamState = { status: "idle" };

  const loadCapabilities = async () => {
    try {
      const snapshots = await deps.inderun.checkCapabilities();
      capabilitiesState = { status: "ready", snapshots };
    } catch {
      capabilitiesState = { status: "error" };
    }
    render();
  };

  /** Streams one simplification, patching the output in place so typing focus is not lost. */
  const streamSimplification = async (
    text: string,
    running: Extract<SimplifyState, { status: "running" }>
  ): Promise<SimplifyState> => {
    const run = { privacy: running.privacy, delivery: running.delivery };
    let stream: TextStream;
    try {
      stream = await streamText(deps.inderun, simplifyOptions(text, run.privacy));
    } catch (error) {
      // Validation and routing refusals reject the call itself: there is no run to stop.
      return { status: "failed", ...run, text: "", error: toIndeRunException(error) };
    }

    running.cancel = (reason) => stream.cancel(reason);
    render();

    try {
      for await (const delta of stream.textStream) {
        running.text += delta;
        const output = root.querySelector<HTMLElement>("#simplify-output");
        if (output) output.textContent = running.text;
      }
    } catch {
      // `result` below reports how the run ended, with its provenance.
    }

    try {
      const result = await stream.result;
      return {
        status: "done",
        ...run,
        text: result.text,
        stopped: result.finishReason === "cancelled",
        provenance: result.provenance
      };
    } catch (error) {
      return { status: "failed", ...run, text: running.text, error: toIndeRunException(error) };
    }
  };

  const runSimplify = async () => {
    const text = ui.simplifyText.trim();
    if (simplify.status === "running" || text.length === 0) {
      return;
    }
    const running: Extract<SimplifyState, { status: "running" }> = {
      status: "running",
      privacy: ui.privacy,
      delivery: ui.delivery,
      text: ""
    };
    simplify = running;
    render();

    if (running.delivery === "stream") {
      simplify = await streamSimplification(text, running);
    } else {
      try {
        const result = await generateText(deps.inderun, simplifyOptions(text, running.privacy));
        simplify = {
          status: "done",
          privacy: running.privacy,
          delivery: running.delivery,
          text: result.text,
          stopped: false,
          provenance: result.provenance
        };
      } catch (error) {
        simplify = {
          status: "failed",
          privacy: running.privacy,
          delivery: running.delivery,
          text: "",
          error: toIndeRunException(error)
        };
      }
    }

    render();
    void loadCapabilities();
  };

  const render = () => {
    const online = isOnline();
    const streaming = streamState.status === "streaming";
    const snapshots =
      capabilitiesState.status === "ready" ? capabilitiesState.snapshots : undefined;

    root.innerHTML = `
      <main class="shell">
        <section class="hero">
          <p class="eyebrow">IndeRun Web Reference Demo</p>
          <h1 class="title">Simplify text, see where it ran</h1>
          <p class="lede">
            Rewrites dense text in plain language through the primary text API
            (<code class="code">generateText()</code> / <code class="code">streamText()</code>),
            on this device when it can and in the cloud only when you allow it. Every result says
            where it ran, from IndeRun's normalized execution provenance.
          </p>
          <div class="pill-row">
            <span class="pill">Primary text API</span>
            <span class="pill">Model profile: ${escapeHtml(SIMPLIFY_PROFILE)}</span>
            <span class="pill">Cloud only when permitted</span>
            <span class="pill">Execution provenance</span>
          </div>
        </section>

        ${renderSimplifyComposer(ui, simplify, snapshots, profileTargets, online, catalog)}

        <section class="grid">
          <article class="panel">
            <h2 class="subtitle">Simplified text</h2>
            ${renderSimplifyOutput(simplify, online, catalog)}
          </article>
          <article class="panel">
            <h2 class="subtitle">Where it ran</h2>
            ${renderSimplifyProvenance(simplify, catalog)}
          </article>
        </section>

        <details id="advanced" class="panel advanced" ${ui.advancedOpen ? "open" : ""}>
          <summary class="subtitle">Advanced: task API</summary>
          <p class="hint">
            These panels call <code class="code">run()</code>, <code class="code">stream()</code> and
            <code class="code">checkCapabilities()</code> directly with a hand-built
            <code class="code">TaskRequest</code>, routing across every registered target (no model profile).
          </p>

          <section class="panel composer">
            <h2 class="subtitle">Privacy Preference</h2>
            <div class="mode-selector">
              ${PRIVACY_OPTIONS.map(
                (option) =>
                  `<button data-privacy="${option.value}" class="preference-btn ${state.privacy === option.value ? "active" : ""}">${option.label}</button>`
              ).join("")}
            </div>

            <label class="label" for="prompt">Prompt</label>
            <textarea id="prompt" name="prompt" rows="5" placeholder="Enter text to send through IndeRun.">${escapeHtml(
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
                On-device model: <code class="code">${escapeHtml(deps.config.onDeviceModel ?? "deterministic fixture runtime")}</code>
              </p>
            </div>
          </section>

          <section class="panel composer">
            <h2 class="subtitle">Provider Availability</h2>
            ${renderCapabilitiesPanel(capabilitiesState)}
          </section>

          <section class="grid">
            <article class="panel">
              <h2 class="subtitle">Result</h2>
              ${renderOutputPanel(state)}
            </article>

            <article class="panel">
              <h2 class="subtitle">Attempt Metadata</h2>
              ${renderRunMetadata(state)}
            </article>
          </section>

          <section class="panel composer">
            <h2 class="subtitle">Streaming (Mode 2)</h2>
            ${renderStreamPanel(streamState)}
          </section>

          <section class="panel composer">
            <h2 class="subtitle">Routing Decision</h2>
            ${renderRoutingDecision(state)}
          </section>
        </details>

        <section class="panel limitations">
          <h2 class="subtitle">Known Limitations</h2>
          <ul>
            <li>Simplified text is machine-generated. It can be wrong or leave things out, and it is not a certified plain-language or easy-to-read translation.</li>
            <li>On-device availability depends on the browser and device. Nothing here assumes an on-device model exists; the device status and each run's provenance say what was actually available.</li>
            <li>On-device ONNX routing uses the Web ONNX Runtime provider. Without <code class="code">VITE_INDERUN_ONNX_MODEL_ID</code> it runs a deterministic fixture runtime that echoes its input instead of real model weights.</li>
            <li>The browser built-in model (Prompt API) requires Chrome 138+ on desktop. It shows as unavailable in other browsers &mdash; this is expected, not a bug.</li>
            <li>Neither on-device target streams on the web yet, so <code class="code">streamText()</code> can only run on the cloud target.</li>
            <li>The browser never carries production secrets. The standalone demo proxy resolves the upstream endpoint, model and bearer token server-side.</li>
          </ul>
        </section>
      </main>
    `;

    bindSimplifyControls();
    bindAdvancedControls();
  };

  const bindSimplifyControls = () => {
    const input = root.querySelector<HTMLTextAreaElement>("#simplify-input");
    const button = root.querySelector<HTMLButtonElement>("#simplify-button");
    if (!input || !button) {
      throw new Error("Demo UI failed to render the simplification controls.");
    }

    input.addEventListener("input", () => {
      ui.simplifyText = input.value;
    });
    root.querySelectorAll<HTMLInputElement>('input[name="simplify-privacy"]').forEach((radio) => {
      radio.addEventListener("change", () => {
        ui.privacy = radio.value as Privacy;
        render();
      });
    });
    root.querySelectorAll<HTMLInputElement>('input[name="simplify-delivery"]').forEach((radio) => {
      radio.addEventListener("change", () => {
        ui.delivery = radio.value as Delivery;
        render();
      });
    });
    button.addEventListener("click", () => {
      ui.simplifyText = input.value;
      void runSimplify();
    });
    root.querySelector<HTMLButtonElement>("#stop-button")?.addEventListener("click", () => {
      if (simplify.status === "running") {
        simplify.cancel?.("user stopped");
      }
    });
  };

  const bindAdvancedControls = () => {
    const details = root.querySelector<HTMLDetailsElement>("#advanced");
    const promptField = root.querySelector<HTMLTextAreaElement>("#prompt");
    const runButton = root.querySelector<HTMLButtonElement>("#run-button");
    const streamButton = root.querySelector<HTMLButtonElement>("#stream-button");
    const preferenceButtons = root.querySelectorAll<HTMLButtonElement>("[data-privacy]");

    if (
      !details ||
      !promptField ||
      !runButton ||
      !streamButton ||
      preferenceButtons.length !== PRIVACY_OPTIONS.length
    ) {
      throw new Error("Demo UI failed to render required controls.");
    }

    details.addEventListener("toggle", () => {
      ui.advancedOpen = details.open;
    });

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
        const result = await deps.inderun.run(taskRequest(prompt, state.privacy));
        state = {
          ...state,
          status: "success",
          result,
          routeDecision: deps.getLastRouteDecision()
        };
      } catch (error) {
        state = {
          ...state,
          status: "error",
          error: toIndeRunException(error),
          routeDecision: deps.getLastRouteDecision()
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
        run = await deps.inderun.stream(taskRequest(prompt, state.privacy));
      } catch (error) {
        // A routing refusal rejects the stream() call itself: no handle, no events.
        streamState = { status: "rejected", error: toIndeRunException(error) };
        render();
        return;
      }

      // The stored state is the object the loop below mutates, so any full
      // re-render mid-stream (a connectivity change, say) redraws the text so far.
      const live: Extract<StreamState, { status: "streaming" }> = {
        status: "streaming",
        text: "",
        log: [],
        cancel: (reason) => run.cancel(reason)
      };
      streamState = live;
      render();

      // Patch the two stream elements in place rather than re-rendering the whole
      // app per event, so a delta does not steal focus from the prompt field.
      let summary = "The provider stream ended without a terminal event.";
      try {
        for await (const event of run.events) {
          live.text = applyStreamEvent(event, live.text);
          live.log.push(streamLogEntry(event));
          if (event.type === "terminal") {
            summary = terminalSummary(event);
          }
          const output = root.querySelector<HTMLElement>("#stream-output");
          const log = root.querySelector<HTMLElement>("#stream-log");
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

  // Connectivity changes the honest state on screen, so redraw when it flips.
  if (typeof window !== "undefined") {
    window.addEventListener("online", () => render());
    window.addEventListener("offline", () => render());
  }

  render();
  void loadCapabilities();
}

function renderSimplifyComposer(
  ui: { simplifyText: string; privacy: Privacy; delivery: Delivery },
  simplify: SimplifyState,
  snapshots: ProviderCapabilitySnapshot[] | undefined,
  profileTargets: string[],
  online: boolean,
  catalog: TargetCatalog
): string {
  const running = simplify.status === "running";
  const stoppable = running && simplify.cancel !== undefined;
  const streamingSelected = ui.delivery === "stream" || (running && simplify.delivery === "stream");

  return `
    <section class="panel composer simplify" aria-labelledby="simplify-heading">
      <h2 id="simplify-heading" class="subtitle">Simplify text</h2>
      <label class="label" for="simplify-input">Text to simplify</label>
      <textarea id="simplify-input" name="simplify-input" rows="6">${escapeHtml(ui.simplifyText)}</textarea>

      <div class="choice-row">
        ${renderChoiceGroup(
          "simplify-privacy",
          "Where may this text be processed?",
          SIMPLIFY_PRIVACY_OPTIONS,
          ui.privacy,
          running
        )}
        ${renderChoiceGroup(
          "simplify-delivery",
          "How should the result arrive?",
          DELIVERY_OPTIONS,
          ui.delivery,
          running
        )}
      </div>

      <div class="actions">
        <div class="button-row">
          <button id="simplify-button" type="button" ${running ? "disabled" : ""}>
            ${running ? "Simplifying..." : "Simplify"}
          </button>
          ${
            streamingSelected
              ? `<button id="stop-button" type="button" class="secondary" ${stoppable ? "" : "disabled"}>Stop</button>`
              : ""
          }
        </div>
        <p class="hint">Machine-generated output can be wrong or leave things out. Check it against the original.</p>
      </div>

      <p class="result-label">What can run here now</p>
      ${renderDeviceStatus(snapshots, profileTargets, online, catalog)}
      <p class="hint">From <code class="code">checkCapabilities()</code>. Availability can change before a run; each run's provenance records what actually happened.</p>

      <details class="call">
        <summary>The call this makes</summary>
        <pre class="code">${escapeHtml(callSnippet(ui.delivery, ui.privacy))}</pre>
      </details>
    </section>
  `;
}

function renderChoiceGroup<T extends string>(
  name: string,
  legend: string,
  options: Array<{ value: T; label: string; hint: string }>,
  selected: T,
  disabled: boolean
): string {
  return `
    <fieldset class="choice-group" ${disabled ? "disabled" : ""}>
      <legend class="label">${escapeHtml(legend)}</legend>
      ${options
        .map(
          (option) => `
            <label class="choice ${option.value === selected ? "active" : ""}">
              <input type="radio" name="${name}" value="${option.value}" ${option.value === selected ? "checked" : ""} />
              <span class="choice-label">${escapeHtml(option.label)}</span>
              <span class="choice-hint">${escapeHtml(option.hint)}</span>
            </label>
          `
        )
        .join("")}
    </fieldset>
  `;
}

function callSnippet(delivery: Delivery, privacy: Privacy): string {
  const head =
    delivery === "stream"
      ? "const { textStream, result, cancel } = await streamText(inderun, {"
      : "const { text, provenance } = await generateText(inderun, {";
  return [
    head,
    `  model: "${SIMPLIFY_PROFILE}",`,
    "  system: PLAIN_LANGUAGE_INSTRUCTION,",
    "  prompt: text,",
    `  execution: { privacy: "${privacy}" }`,
    "});"
  ].join("\n");
}

function renderSimplifyOutput(
  simplify: SimplifyState,
  online: boolean,
  catalog: TargetCatalog
): string {
  switch (simplify.status) {
    case "idle":
      return `<p class="placeholder">Press Simplify to rewrite the text above.</p>`;
    case "running":
      return `
        <div class="result">
          <p class="status-line" role="status">${simplify.delivery === "stream" ? "Streaming..." : "Waiting for the whole result..."}</p>
          <pre id="simplify-output" aria-live="polite">${escapeHtml(simplify.text)}</pre>
        </div>
      `;
    case "done": {
      const notices = outcomeNotices({
        privacy: simplify.privacy,
        delivery: simplify.delivery,
        online,
        provenance: simplify.provenance,
        catalog
      });
      return `
        <div class="result ${simplify.stopped ? "stopped" : "success"}">
          <p class="status-line" role="status">${
            simplify.stopped ? "Stopped. Below is the text delivered before the stop." : "Done."
          }</p>
          <pre id="simplify-output">${escapeHtml(simplify.text) || '<span class="placeholder">No text was delivered.</span>'}</pre>
          ${renderNotices(notices)}
        </div>
      `;
    }
    case "failed": {
      const notices = outcomeNotices({
        privacy: simplify.privacy,
        delivery: simplify.delivery,
        online,
        provenance: simplify.error.provenance,
        error: simplify.error,
        catalog
      });
      return `
        <div class="result failure">
          <p class="status-line" role="status">Could not simplify: <strong class="error-class">${escapeHtml(simplify.error.errorClass)}</strong></p>
          <p>${escapeHtml(simplify.error.message)}</p>
          ${
            simplify.text
              ? `<p class="result-label">Delivered before the failure</p><pre id="simplify-output">${escapeHtml(simplify.text)}</pre>`
              : ""
          }
          ${renderNotices(notices)}
        </div>
      `;
    }
  }
}

function renderSimplifyProvenance(simplify: SimplifyState, catalog: TargetCatalog): string {
  switch (simplify.status) {
    case "idle":
      return `<p class="placeholder">After a run, this shows where it ran, which target and model, and whether IndeRun fell back &mdash; all from <code class="code">result.provenance</code>.</p>`;
    case "running":
      return `<p class="placeholder">Provenance arrives with the outcome.</p>`;
    case "done":
      return renderProvenance(simplify.provenance, catalog);
    case "failed":
      return renderProvenance(simplify.error.provenance, catalog);
  }
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
          <pre>${escapeHtml(state.result.output.text ?? "")}</pre>
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

function renderRoutingDecision(state: AppState): string {
  if (state.status !== "success" && state.status !== "error") {
    return `<p class="placeholder">No run yet. The routing decision appears after the first attempt.</p>`;
  }

  const decision = state.routeDecision;
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
      <div class="meta-item"><dt>Explanation</dt><dd>${escapeHtml(decision.explanation)}</dd></div>
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
