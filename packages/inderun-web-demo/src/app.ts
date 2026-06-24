import type { TaskResult } from "@independo/inderun-contracts";
import { type IndeRunException, toIndeRunException } from "@independo/inderun-web";

const DEFAULT_PROMPT = "Write a terse status update explaining what IndeRun routed and why it matters.";

export interface AppDependencies {
  config: {
    model: string;
    proxyEndpointUrl: string;
  };
  runPrompt(prompt: string, executionMode: "on_device" | "cloud"): Promise<TaskResult>;
}

type ExecutionMode = "on_device" | "cloud";

type AppState =
  | {
      status: "idle" | "running";
      prompt: string;
      executionMode: ExecutionMode;
    }
  | {
      status: "success";
      prompt: string;
      executionMode: ExecutionMode;
      result: TaskResult;
    }
  | {
      status: "error";
      prompt: string;
      executionMode: ExecutionMode;
      error: IndeRunException;
    };

export function mountApp(root: HTMLElement, deps: AppDependencies): void {
  let state: AppState = {
    status: "idle",
    prompt: DEFAULT_PROMPT,
    executionMode: "cloud"
  };

  const render = () => {
    const runMetadata = renderRunMetadata(state);
    const outputPanel = renderOutputPanel(state);

    root.innerHTML = `
      <main class="shell">
        <section class="hero">
          <p class="eyebrow">Issue #11 / Web Workpackage</p>
          <h1 class="title">IndeRun Execution Demo</h1>
          <p class="lede">
            Minimal review app for the canonical <code class="code">run()</code> flow on the web:
            prompt in, execution through the local proxy, normalized result or error out.
          </p>
          <div class="pill-row">
            <span class="pill">Mode 1</span>
            <span class="pill">Policy Driven</span>
            <span class="pill">Proxy-Backed</span>
          </div>
        </section>

        <section class="panel composer">
          <h2 class="subtitle">Execution Mode</h2>
          <div class="mode-selector">
            <button id="mode-on-device" class="mode-btn ${state.executionMode === 'on_device' ? 'active' : ''}">On Device</button>
            <button id="mode-cloud" class="mode-btn ${state.executionMode === 'cloud' ? 'active' : ''}">Cloud</button>
          </div>

          <label class="label" for="prompt">Prompt</label>
          <textarea id="prompt" name="prompt" rows="8" placeholder="Enter text to send through IndeRun.">${escapeHtml(
            state.prompt
          )}</textarea>
          <div class="actions">
            <button id="run-button" type="button" ${state.status === "running" ? "disabled" : ""}>
              ${state.status === "running" ? "Running..." : state.executionMode === 'on_device' ? "Run On Device" : "Run Through Cloud"}
            </button>
            <p class="hint">Endpoint: <code class="code">${escapeHtml(deps.config.proxyEndpointUrl)}</code></p>
          </div>
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

        <section class="panel limitations">
          <h2 class="subtitle">Known Limitations</h2>
          <ul>
            <li>On-device routing requires a local provider setup that matches the policy.</li>
            <li>The browser never carries production secrets. The standalone demo proxy resolves upstream endpoint and bearer-token configuration server-side.</li>
            <li>The canonical result field is <code class="code">telemetry.totalMs</code>, not <code class="timing">timing.totalMs</code>.</li>
          </ul>
        </section>
      </main>
    `;

    const promptField = root.querySelector<HTMLTextAreaElement>("#prompt");
    const runButton = root.querySelector<HTMLButtonElement>("#run-button");
    const modeOnDeviceBtn = root.querySelector<HTMLButtonElement>("#mode-on-device");
    const modeCloudBtn = root.querySelector<HTMLButtonElement>("#mode-cloud");

    if (!promptField || !runButton || !modeOnDeviceBtn || !modeCloudBtn) {
      throw new Error("Demo UI failed to render required controls.");
    }

    promptField.addEventListener("input", (event) => {
      const target = event.currentTarget as HTMLTextAreaElement;
      state = { ...state, prompt: target.value };
    });

    modeOnDeviceBtn.addEventListener("click", () => {
      state = { ...state, executionMode: "on_device" };
      render();
    });

    modeCloudBtn.addEventListener("click", () => {
      state = { ...state, executionMode: "cloud" };
      render();
    });

    runButton.addEventListener("click", async () => {
      const prompt = promptField.value.trim();
      state = { ...state, status: "running", prompt };
      render();

      try {
        const result = await deps.runPrompt(prompt, state.executionMode);
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

      render();
    });
  };

  render();
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
