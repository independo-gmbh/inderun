import type { TaskResult } from "@independo/inderun-contracts";
import { type IndeRunException, toIndeRunException } from "@independo/inderun-web";

const DEFAULT_PROMPT = "Write a terse status update explaining what IndeRun routed and why it matters.";

export interface AppDependencies {
  config: {
    model: string;
    proxyEndpointUrl: string;
  };
  runPrompt(prompt: string): Promise<TaskResult>;
}

type AppState =
  | {
      status: "idle" | "running";
      prompt: string;
    }
  | {
      status: "success";
      prompt: string;
      result: TaskResult;
    }
  | {
      status: "error";
      prompt: string;
      error: IndeRunException;
    };

export function mountApp(root: HTMLElement, deps: AppDependencies): void {
  let state: AppState = {
    status: "idle",
    prompt: DEFAULT_PROMPT
  };

  const render = () => {
    const runMetadata = renderRunMetadata(state);
    const outputPanel = renderOutputPanel(state);

    root.innerHTML = `
      <main class="shell">
        <section class="hero">
          <p class="eyebrow">Issue #11 / Web Workpackage</p>
          <h1>IndeRun Cloud Run Demo</h1>
          <p class="lede">
            Minimal review app for the canonical <code>run()</code> flow on the web:
            prompt in, cloud execution through the local proxy, normalized result or error out.
          </p>
          <div class="pill-row">
            <span class="pill">Mode 1</span>
            <span class="pill">Cloud Only</span>
            <span class="pill">Proxy-Backed</span>
          </div>
        </section>

        <section class="panel composer">
          <label class="label" for="prompt">Prompt</label>
          <textarea id="prompt" name="prompt" rows="8" placeholder="Enter text to send through IndeRun.">${escapeHtml(
            state.prompt
          )}</textarea>
          <div class="actions">
            <button id="run-button" type="button" ${state.status === "running" ? "disabled" : ""}>
              ${state.status === "running" ? "Running..." : "Run Through Cloud"}
            </button>
            <p class="hint">Endpoint: <code>${escapeHtml(deps.config.proxyEndpointUrl)}</code></p>
          </div>
        </section>

        <section class="grid">
          <article class="panel">
            <h2>Result</h2>
            ${outputPanel}
          </article>

          <article class="panel">
            <h2>Attempt Metadata</h2>
            ${runMetadata}
          </article>
        </section>

        <section class="panel limitations">
          <h2>Known Limitations</h2>
          <ul>
            <li>This demo is intentionally cloud-only; on-device routing belongs to the native demo workpackages.</li>
            <li>The browser never carries production secrets. The standalone demo proxy resolves upstream endpoint and bearer-token configuration server-side.</li>
            <li>The canonical result field is <code>telemetry.totalMs</code>, not <code>timing.totalMs</code>.</li>
          </ul>
        </section>
      </main>
    `;

    const promptField = root.querySelector<HTMLTextAreaElement>("#prompt");
    const runButton = root.querySelector<HTMLButtonElement>("#run-button");

    if (!promptField || !runButton) {
      throw new Error("Demo UI failed to render required controls.");
    }

    promptField.addEventListener("input", (event) => {
      const target = event.currentTarget as HTMLTextAreaElement;
      state = { ...state, prompt: target.value };
    });

    runButton.addEventListener("click", async () => {
      const prompt = promptField.value.trim();
      state = { status: "running", prompt };
      render();

      try {
        const result = await deps.runPrompt(prompt);
        state = {
          status: "success",
          prompt,
          result
        };
      } catch (error) {
        state = {
          status: "error",
          prompt,
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
          <p><strong>${escapeHtml(state.error.errorClass)}</strong></p>
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
        <div><dt>Run ID</dt><dd>${escapeHtml(state.result.runId)}</dd></div>
        <div><dt>Provider Used</dt><dd>${escapeHtml(state.result.telemetry.providerUsed)}</dd></div>
        <div><dt>Total ms</dt><dd>${formatMs(state.result.telemetry.totalMs)}</dd></div>
        <div><dt>Finish Reason</dt><dd>${escapeHtml(state.result.finishReason)}</dd></div>
      </dl>
    `;
  }

  if (state.status === "error") {
    return `
      <dl class="meta">
        <div><dt>Run ID</dt><dd>${escapeHtml(state.error.runId ?? "unavailable")}</dd></div>
        <div><dt>Provider Used</dt><dd>${escapeHtml(state.error.providerId ?? "unavailable")}</dd></div>
        <div><dt>Total ms</dt><dd>${formatMs(getErrorTotalMs(state.error.details))}</dd></div>
        <div><dt>Error Class</dt><dd>${escapeHtml(state.error.errorClass)}</dd></div>
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
    <pre>${escapeHtml(`${name}: ${message}`)}</pre>
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
