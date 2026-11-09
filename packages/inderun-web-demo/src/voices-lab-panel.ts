import {
  IndeRunException,
  generateSpeech as sdkGenerateSpeech,
  listVoices as sdkListVoices,
  prepare as sdkPrepare,
  speak as sdkSpeak,
  type IndeRunApi,
  type SpeechPlayback,
  type SpeechVoiceInfo
} from "@independo/inderun-web";
import type { SpeechPackageFiles } from "@independo/inderun-web/neural-speech";
import {
  catalogEntryToModelPackage,
  entryFiles,
  entryRef,
  entryTotalBytes,
  isInstallable,
  unavailableReason,
  labProfileName,
  neuralProviderId,
  type CatalogEntry,
  type InstalledModel,
  type NeuralCatalog
} from "./neural-catalog";
import {
  downloadEntry,
  isDownloadCancelled,
  isVerified,
  type ConsentPrompt,
  type ModelStorage
} from "./neural-downloader";
import sdkPackage from "../../inderun-web/package.json";
import type { VoicesLabEngine } from "./voices-lab-engine";
import {
  buildReport,
  describeBrowser,
  reportSdkVersion,
  runCorpus,
  withAudio,
  type BenchmarkCorpus,
  type BenchmarkRun,
  type ReportTarget
} from "./voices-lab-benchmark";

const LANGUAGES = [
  { tag: "de-DE", label: "Deutsch (Deutschland)" },
  { tag: "de-AT", label: "Deutsch (Österreich)" },
  { tag: "en-US", label: "English (US)" },
  { tag: "en-GB", label: "English (UK)" }
];
const CONTROL = "control";
const SYSTEM_SPEECH_PROVIDER_ID = "web_system_speech";

/** Where one entry is stored and how the runtime reads it back. */
export interface EntryStore {
  ref: string;
  storage: ModelStorage;
  files: SpeechPackageFiles;
}

export interface VoicesLabCorpus extends BenchmarkCorpus {
  /** Longer sentences for the presets and the neural render run (#276). */
  extendedUtterances?: BenchmarkCorpus["utterances"];
}

/** The SDK calls the panel makes, replaceable in tests. */
export interface VoicesLabApi {
  speak: typeof sdkSpeak;
  listVoices: typeof sdkListVoices;
  prepare: typeof sdkPrepare;
  generateSpeech: typeof sdkGenerateSpeech;
}

export interface VoicesLabOptions {
  /** `VITE_INDERUN_VOICES_LAB=1`. When false the panel does nothing at all. */
  enabled: boolean;
  catalog: NeuralCatalog;
  corpus: VoicesLabCorpus;
  /** The demo proxy's `/assets` URL. */
  assetsUrl: string;
  fetch: typeof fetch;
  /** Absent when the browser has no Origin Private File System. */
  openEntryStore?: (
    entry: CatalogEntry,
    mode: { create: boolean }
  ) => Promise<EntryStore | undefined>;
  /** Asked for only after the person consented to a download (`navigator.storage.persist()`). */
  requestPersistence?: () => Promise<void>;
  /** Builds the lab engine for the installed models; called again after each install. */
  createEngine: (installed: InstalledModel[]) => VoicesLabEngine;
  api?: Partial<VoicesLabApi>;
  /** Saves an exported report; defaults to a Blob and an `<a download>` click. */
  download?: (name: string, json: string) => void;
  /** Millisecond clock for the corpus run; defaults to `performance.now()`. */
  now?: () => number;
  /** The corpus runner, replaceable in tests. */
  runBenchmark?: typeof runCorpus;
}

function downloadViaAnchor(name: string, json: string): void {
  const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = name;
  anchor.click();
  URL.revokeObjectURL(url);
}

/** Anything outside `[A-Za-z0-9._-]` becomes `-`. */
function fileSafe(value: string): string {
  return Array.from(value, (c) => (/^[A-Za-z0-9._-]$/u.test(c) ? c : "-")).join("");
}

function megabytes(bytes: number): string {
  return `${Math.round(bytes / 1_000_000)} MB`;
}

function describeError(error: unknown): string {
  return error instanceof IndeRunException
    ? `${error.errorClass}: ${error.message}`
    : error instanceof Error
      ? error.message
      : String(error);
}

/**
 * The opt-in Voices lab: download a neural speech model with consent into the Origin Private File
 * System, then speak it next to the OS voice. Requests go through the model profile
 * `voices-lab:<entry id>` on the lab engine, never a model id; "OS TTS (control)" goes through the
 * demo's own engine. Resolves once the installed models are registered and the controls are filled.
 */
export async function mountVoicesLabPanel(
  root: HTMLElement,
  inderun: IndeRunApi,
  options: VoicesLabOptions
): Promise<void> {
  if (!options.enabled) return;
  const api: VoicesLabApi = {
    speak: options.api?.speak ?? sdkSpeak,
    listVoices: options.api?.listVoices ?? sdkListVoices,
    prepare: options.api?.prepare ?? sdkPrepare,
    generateSpeech: options.api?.generateSpeech ?? sdkGenerateSpeech
  };
  const entries = options.catalog.entries;
  const installable = entries.filter(isInstallable);
  const unavailable = entries.filter((entry) => !isInstallable(entry));

  root.innerHTML = `
    <section class="panel" aria-labelledby="lab-heading">
      <h2 id="lab-heading">Voices lab</h2>
      <p>Experimental: neural voices run in this browser and are compared with the OS voice.</p>
      <label for="lab-language">Language</label>
      <select id="lab-language"></select>
      <label for="lab-model">Model</label>
      <select id="lab-model"></select>
      <label for="lab-voice">Voice</label>
      <select id="lab-voice"></select>
      <label for="lab-preset">Preset text</label>
      <select id="lab-preset"></select>
      <label for="lab-text">Text to speak</label>
      <textarea id="lab-text" rows="3"></textarea>
      <div class="actions">
        <button id="lab-speak" type="button">Speak</button>
        <button id="lab-stop" type="button" disabled>Stop</button>
        <button id="lab-repeat" type="button" disabled>Repeat</button>
        <button id="lab-ab" type="button">A/B: neural, then OS</button>
        <button id="lab-download" type="button">Download model</button>
        <button id="lab-cancel-download" type="button" hidden>Cancel download</button>
      </div>
      <div class="actions">
        <button id="lab-run-corpus" type="button">Run corpus (plays audio)</button>
        <button id="lab-export" type="button" disabled>Export report</button>
        <label for="lab-export-audio">
          <input id="lab-export-audio" type="checkbox" /> Include rendered audio
        </label>
      </div>
      <p id="lab-run-status" role="status" aria-live="polite"></p>
      <p id="lab-storage-note"></p>
      <p id="lab-unavailable"></p>
      <div id="lab-consent" role="alertdialog" aria-labelledby="lab-consent-title" hidden>
        <h3 id="lab-consent-title">Download this model?</h3>
        <p id="lab-consent-body"></p>
        <div class="actions">
          <button id="lab-consent-accept" type="button">Download</button>
          <button id="lab-consent-decline" type="button">Cancel</button>
        </div>
      </div>
      <progress id="lab-progress" max="100" value="0" hidden></progress>
      <p id="lab-status" role="status" aria-live="polite"></p>
      <dl id="lab-status-card"></dl>
    </section>`;

  const q = <T extends HTMLElement>(id: string) => root.querySelector<T>(`#${id}`)!;
  const language = q<HTMLSelectElement>("lab-language");
  const model = q<HTMLSelectElement>("lab-model");
  const voice = q<HTMLSelectElement>("lab-voice");
  const preset = q<HTMLSelectElement>("lab-preset");
  const text = q<HTMLTextAreaElement>("lab-text");
  const speakButton = q<HTMLButtonElement>("lab-speak");
  const stopButton = q<HTMLButtonElement>("lab-stop");
  const repeatButton = q<HTMLButtonElement>("lab-repeat");
  const abButton = q<HTMLButtonElement>("lab-ab");
  const downloadButton = q<HTMLButtonElement>("lab-download");
  const runCorpusButton = q<HTMLButtonElement>("lab-run-corpus");
  const exportButton = q<HTMLButtonElement>("lab-export");
  const exportAudio = q<HTMLInputElement>("lab-export-audio");
  const runStatus = q("lab-run-status");
  const cancelDownloadButton = q<HTMLButtonElement>("lab-cancel-download");
  const storageNote = q("lab-storage-note");
  const consentBox = q("lab-consent");
  const consentBody = q("lab-consent-body");
  const progress = q<HTMLProgressElement>("lab-progress");
  const status = q("lab-status");
  const card = q("lab-status-card");

  const option = (value: string, label: string, disabled = false) => {
    const element = document.createElement("option");
    element.value = value;
    element.textContent = label;
    element.disabled = disabled;
    return element;
  };

  for (const { tag, label } of LANGUAGES) language.append(option(tag, label));
  language.value = "de-DE";

  const utterances = [
    ...options.corpus.utterances,
    ...(options.corpus.extendedUtterances ?? [])
  ].filter((u) => u.expect !== "refuse");
  preset.append(option("", "Custom text"));
  for (const utterance of utterances) {
    preset.append(option(utterance.id, `${utterance.id} (${utterance.locale})`));
  }
  const first = utterances.find((u) => u.locale === "de-DE") ?? utterances[0];
  text.value = first?.text ?? "";
  preset.addEventListener("change", () => {
    const picked = utterances.find((u) => u.id === preset.value);
    if (picked === undefined) return;
    text.value = picked.text;
    if (LANGUAGES.some((l) => l.tag === picked.locale)) language.value = picked.locale;
  });

  const store = new Map<string, EntryStore>();
  const installedIds = new Set<string>();
  let engine: IndeRunApi | undefined;
  let labEngine: VoicesLabEngine | undefined;
  let neuralVoices: SpeechVoiceInfo[] = [];
  let controlVoices: SpeechVoiceInfo[] = [];

  const supported = options.openEntryStore !== undefined;
  if (!supported) {
    storageNote.textContent = "This browser cannot store models (no Origin Private File System).";
    downloadButton.disabled = true;
  }
  unavailable.forEach((entry) => {
    const reason = unavailableReason(entry);
    model.append(option(entry.id, `${entry.variant} Core AI (unavailable)`, true));
    const line = document.createElement("span");
    line.textContent = `${entry.id}: unavailable, ${reason}. `;
    q("lab-unavailable").append(line);
  });

  const entryOf = (id: string) => installable.find((entry) => entry.id === id);
  const selectedEntry = () => entryOf(model.value);
  const isControl = () => model.value === CONTROL;

  async function isInstalled(entry: CatalogEntry): Promise<boolean> {
    if (options.openEntryStore === undefined) return false;
    // Read-only: mounting must not create directories or ask for anything.
    const opened = store.get(entry.id) ?? (await options.openEntryStore(entry, { create: false }));
    if (opened === undefined) return false;
    store.set(entry.id, opened);
    // Size and sha256, as a download checks them: the runtime does not verify the package again, so a
    // damaged or replaced file of the right length would otherwise be trusted on every later run.
    for (const file of entryFiles(entry)) {
      if (!(await isVerified(opened.storage, file))) return false;
    }
    return true;
  }

  function installedModels(): InstalledModel[] {
    return installable
      .filter((entry) => installedIds.has(entry.id))
      .map((entry) => {
        const opened = store.get(entry.id)!;
        return {
          entry,
          modelPackage: catalogEntryToModelPackage(entry, opened.ref || entryRef(entry)),
          files: opened.files
        };
      });
  }

  async function rebuildEngine(): Promise<void> {
    const installed = installedModels();
    const previous = labEngine;
    labEngine = installed.length === 0 ? undefined : options.createEngine(installed);
    engine = labEngine?.engine;
    // The replaced engine and the runtimes the demo created for it are closed (voices-lab-engine.ts).
    await previous?.close();
  }

  function renderModels(): void {
    const keep = model.value;
    model.replaceChildren();
    for (const entry of installable) {
      const mark = installedIds.has(entry.id) ? "" : " (not downloaded)";
      model.append(option(entry.id, `${entry.id} ${entry.variant}${mark}`));
    }
    model.append(option(CONTROL, "OS TTS (control)"));
    unavailable.forEach((entry) =>
      model.append(option(entry.id, `${entry.variant} Core AI (unavailable)`, true))
    );
    const wanted = [...model.options].some((o) => o.value === keep && !o.disabled)
      ? keep
      : (installable.find((e) => installedIds.has(e.id))?.id ?? installable[0]?.id ?? CONTROL);
    model.value = wanted;
  }

  async function refreshVoices(): Promise<void> {
    if (engine !== undefined) {
      neuralVoices = (await api.listVoices(engine)).filter((v) =>
        installable.some((e) => v.providerId === neuralProviderId(e.id))
      );
    } else {
      neuralVoices = [];
    }
    controlVoices = (await api.listVoices(inderun, { locale: language.value })).filter(
      (v) => v.providerId === SYSTEM_SPEECH_PROVIDER_ID
    );
    renderVoices();
  }

  function currentVoices(): SpeechVoiceInfo[] {
    if (isControl()) return controlVoices;
    const entry = selectedEntry();
    return entry === undefined
      ? []
      : neuralVoices.filter((v) => v.providerId === neuralProviderId(entry.id));
  }

  function renderVoices(): void {
    voice.replaceChildren(option("", "Automatic"));
    currentVoices().forEach((v, index) =>
      voice.append(option(String(index), `${v.name ?? v.id} (${v.locale})`))
    );
    const list = currentVoices();
    if (!isControl() && list.length > 0) voice.value = "0";
  }

  function updateButtons(): void {
    const entry = selectedEntry();
    downloadButton.disabled = !supported || isControl() || entry === undefined;
    downloadButton.textContent =
      entry !== undefined && installedIds.has(entry.id)
        ? "Warm up model"
        : entry !== undefined
          ? `Download model (${megabytes(entryTotalBytes(entry))})`
          : "Download model";
  }

  // Hashing the stored files takes a moment for a model of this size.
  const checking = "Checking stored models…";
  if (supported) status.textContent = checking;
  for (const installable_ of installable) {
    try {
      if (await isInstalled(installable_)) installedIds.add(installable_.id);
    } catch (error) {
      status.textContent = `could not read stored models: ${describeError(error)}`;
    }
  }
  if (status.textContent === checking) status.textContent = "";
  renderModels();
  await rebuildEngine();
  await refreshVoices();
  updateButtons();

  model.addEventListener("change", () => {
    renderVoices();
    updateButtons();
  });
  language.addEventListener("change", () => void refreshVoices());

  // --- Status card ------------------------------------------------------------------------

  function showCard(rows: [string, string | undefined][]): void {
    card.replaceChildren();
    for (const [name, value] of rows) {
      if (value === undefined) continue;
      const dt = document.createElement("dt");
      dt.textContent = name;
      const dd = document.createElement("dd");
      dd.textContent = value;
      card.append(dt, dd);
    }
  }

  // --- Speaking ---------------------------------------------------------------------------

  let current: SpeechPlayback | undefined;
  let aborted = false;
  let last: (() => Promise<void>) | undefined;

  let corpusRunning = false;

  function setBusy(busy: boolean): void {
    speakButton.disabled = busy || corpusRunning;
    abButton.disabled = busy || corpusRunning;
    stopButton.disabled = !busy;
    repeatButton.disabled = busy || corpusRunning || last === undefined;
    runCorpusButton.disabled = busy || corpusRunning;
  }

  /**
   * One utterance through the neural profile or the OS control; fills the status card. Resolves
   * false when a neural request was answered by another provider; for an A/B run (`comparing`) the
   * status then says the comparison is invalid, since the control would be OS against OS.
   */
  async function speakOnce(target: "neural" | "control", comparing = false): Promise<boolean> {
    const entry = selectedEntry();
    const neural = target === "neural";
    if (neural && (entry === undefined || engine === undefined || !installedIds.has(entry.id))) {
      throw new Error("Download the model first.");
    }
    const chosen = currentVoices()[Number(voice.value)];
    const voiceInfo = voice.value === "" ? undefined : isControl() === !neural ? chosen : undefined;
    const request = {
      text: text.value,
      locale: language.value,
      ...(neural ? { model: labProfileName(entry!.id) } : {}),
      ...(voiceInfo !== undefined ? { voice: voiceInfo } : {})
    };
    status.textContent = neural ? "Speaking (neural)…" : "Speaking (OS voice)…";
    const playback = await api.speak(neural ? engine! : inderun, request);
    current = playback;
    if (aborted) playback.cancel("stopped from the demo");
    const done = await playback.result;
    current = undefined;
    const provenance = done.provenance;
    const spoke = provenance?.providerId;
    // The card describes the provider that actually spoke, never the one that was asked.
    const neuralSpoke = neural && spoke === neuralProviderId(entry!.id);
    const fellBack = neural && !neuralSpoke;
    const textOnnx = entry?.files?.find((f) => f.path === "text.onnx");
    const failedAttempt = provenance?.attempts?.find(
      (attempt) =>
        attempt.providerId === neuralProviderId(entry?.id ?? "") && attempt.outcome !== "succeeded"
    );
    const failedNote =
      failedAttempt !== undefined
        ? ` (neural: ${failedAttempt.outcome}${failedAttempt.errorClass ? `, ${failedAttempt.errorClass}` : ""})`
        : "";
    const fallbackNote = fellBack
      ? `fell back to OS voice${
          failedNote !== "" ? failedNote : spoke === undefined ? " (provider not reported)" : ""
        }`
      : undefined;
    showCard([
      ["Provider", spoke ?? (neural ? "not reported" : SYSTEM_SPEECH_PROVIDER_ID)],
      ["Result", fallbackNote],
      [
        "Model",
        neuralSpoke ? `${entry!.id} (${entry!.variant})` : fellBack ? undefined : "OS TTS (control)"
      ],
      [
        "Package checksum",
        neuralSpoke && textOnnx ? `text.onnx sha256:${textOnnx.sha256.slice(0, 12)}…` : undefined
      ],
      [
        "Voice",
        done.speech?.voice?.name ?? (fellBack ? "automatic" : (voiceInfo?.name ?? "automatic"))
      ],
      ["Resolved locale", done.speech?.locale ?? language.value],
      ["Locality", provenance?.locality ?? "unknown"],
      [
        "Runtime",
        neuralSpoke ? "onnxruntime-web (wasm)" : fellBack ? undefined : "browser speechSynthesis"
      ],
      ["Delivery", "playback (generateSpeech would return an artifact)"],
      ["Ended", done.finishReason ?? "stop"],
      [
        "First audio",
        done.timing?.firstAudioMs !== undefined
          ? `${Math.round(done.timing.firstAudioMs)} ms`
          : undefined
      ]
    ]);
    status.textContent =
      fellBack && comparing
        ? `comparison invalid: neural fell back to ${spoke ?? "a provider that was not reported"}${failedNote}; the OS control was skipped`
        : fellBack
          ? `${fallbackNote}: ${done.finishReason ?? "stop"}`
          : `${neural ? "neural" : "OS voice"}: ${done.finishReason ?? "stop"}`;
    return !fellBack;
  }

  async function run(job: () => Promise<void>): Promise<void> {
    aborted = false;
    last = job;
    setBusy(true);
    try {
      await job();
    } catch (error) {
      status.textContent = `failed: ${describeError(error)}`;
    } finally {
      current = undefined;
      setBusy(false);
    }
  }

  speakButton.addEventListener("click", () => {
    const target = isControl() ? "control" : "neural";
    void run(async () => {
      await speakOnce(target);
    });
  });
  abButton.addEventListener("click", () => {
    void run(async () => {
      // A fallback already played the OS voice; the comparison stops there and says so.
      if (!(await speakOnce("neural", true)) || aborted) return;
      await speakOnce("control");
    });
  });
  repeatButton.addEventListener("click", () => {
    if (last !== undefined) void run(last);
  });
  stopButton.addEventListener("click", () => {
    aborted = true;
    current?.cancel("stopped from the demo");
  });

  // --- Corpus run and report export -----------------------------------------------------------

  let lastRun: BenchmarkRun | undefined;

  function targetOf(): { target: ReportTarget; voice: SpeechVoiceInfo | undefined } {
    const chosen = voice.value === "" ? undefined : currentVoices()[Number(voice.value)];
    if (isControl()) {
      return {
        target: { name: SYSTEM_SPEECH_PROVIDER_ID, providerId: SYSTEM_SPEECH_PROVIDER_ID },
        voice: chosen
      };
    }
    const entry = selectedEntry();
    if (entry === undefined || engine === undefined || !installedIds.has(entry.id)) {
      throw new Error("Download the model first.");
    }
    return {
      target: {
        name: entry.id,
        providerId: neuralProviderId(entry.id),
        model: entry.id,
        variant: entry.variant,
        checksums: Object.fromEntries(
          entryFiles(entry).map((file) => [file.path, `sha256:${file.sha256}`])
        ),
        ...(chosen?.id !== undefined ? { voiceId: chosen.id } : {})
      },
      voice: chosen
    };
  }

  runCorpusButton.addEventListener("click", () => {
    if (corpusRunning) return;
    void (async () => {
      corpusRunning = true;
      setBusy(false);
      downloadButton.disabled = true;
      runStatus.textContent = "Running the corpus…";
      try {
        const { target, voice: chosen } = targetOf();
        const control = isControl();
        const run = await (options.runBenchmark ?? runCorpus)({
          api,
          engine: control ? inderun : engine!,
          ...(control ? {} : { profile: labProfileName(selectedEntry()!.id) }),
          ...(chosen !== undefined ? { voice: chosen } : {}),
          corpus: options.corpus,
          target,
          now: options.now ?? (() => performance.now()),
          // A cold trial needs an engine nothing has used yet; the OS control has no such engine.
          // It holds the benchmarked model alone, so its prepare readies no other installed model
          // and prepareMs measures that model only.
          ...(control
            ? {}
            : {
                newEngine: () => {
                  const benchmarked = target.model;
                  const fresh = options.createEngine(
                    installedModels().filter((installed) => installed.entry.id === benchmarked)
                  );
                  return { engine: fresh.engine, close: () => fresh.close() };
                }
              }),
          onProgress: (done, total) => {
            runStatus.textContent = `Running the corpus: scenario ${done} of ${total} done`;
          }
        });
        lastRun = run;
        exportButton.disabled = false;
        downloadReport(run, false);
        runStatus.textContent = `Corpus run finished: ${run.samples.length} samples, ${run.skipped.length} scenarios skipped; report downloaded.`;
      } catch (error) {
        runStatus.textContent = `failed: ${describeError(error)}`;
      } finally {
        corpusRunning = false;
        setBusy(false);
        updateButtons();
      }
    })();
  });

  /** Builds the report for `run` and saves it; the run's own download carries no audio. */
  function downloadReport(run: BenchmarkRun, includeAudio: boolean): void {
    const { device, os } = describeBrowser(navigator);
    const createdAt = new Date().toISOString();
    const sdkVersion = reportSdkVersion(sdkPackage.version, import.meta.env.DEV);
    let report = buildReport(run, { device, os, sdkVersion, createdAt });
    if (includeAudio) report = withAudio(report, run.renders);
    const name = `web_voices_lab-${fileSafe(run.target.name)}-${fileSafe(device)}-${createdAt.slice(0, 10)}.json`;
    (options.download ?? downloadViaAnchor)(name, JSON.stringify(report, null, 2));
  }

  exportButton.addEventListener("click", () => {
    if (lastRun !== undefined) downloadReport(lastRun, exportAudio.checked);
  });

  // --- Download and warm-up ---------------------------------------------------------------

  function askConsent(prompt: ConsentPrompt): Promise<boolean> {
    consentBody.replaceChildren();
    const size = document.createElement("p");
    size.textContent = `${prompt.entry.id} downloads ${megabytes(prompt.totalBytes)} into this browser's private storage.`;
    const licenses = document.createElement("ul");
    for (const line of prompt.licenses) {
      const item = document.createElement("li");
      item.textContent = line;
      licenses.append(item);
    }
    consentBody.append(size, licenses);
    consentBox.hidden = false;
    q<HTMLButtonElement>("lab-consent-accept").focus();
    return new Promise((resolve) => {
      const finish = (answer: boolean) => {
        consentBox.hidden = true;
        q("lab-consent-accept").onclick = null;
        q("lab-consent-decline").onclick = null;
        resolve(answer);
      };
      q("lab-consent-accept").onclick = () => finish(true);
      q("lab-consent-decline").onclick = () => finish(false);
    });
  }

  async function warm(entry: CatalogEntry): Promise<void> {
    if (engine === undefined) return;
    status.textContent = "Loading the model…";
    const preparation = await api.prepare(engine, {
      tasks: ["text_to_speech"],
      locale: language.value,
      onProgress: (p) => {
        if (p.fractionCompleted !== undefined) {
          progress.hidden = false;
          progress.value = Math.round(p.fractionCompleted * 100);
        }
      }
    });
    const result = await preparation.result;
    progress.hidden = true;
    const failed = result.items.filter((item) => item.state === "failed");
    status.textContent =
      failed.length > 0
        ? `${entry.id} could not be prepared: ${failed.map((i) => i.reason ?? i.state).join(", ")}`
        : `${entry.id} is ready.`;
  }

  let cancelDownload: (() => void) | undefined;
  cancelDownloadButton.addEventListener("click", () => cancelDownload?.());

  downloadButton.addEventListener("click", () => {
    const entry = selectedEntry();
    if (entry === undefined || options.openEntryStore === undefined) return;
    void (async () => {
      downloadButton.disabled = true;
      const controller = new AbortController();
      cancelDownload = () => controller.abort();
      try {
        if (!installedIds.has(entry.id)) {
          // The directory is created, and persistence asked for, only once the person consents.
          let opened = store.get(entry.id);
          const target = (): ModelStorage => opened!.storage;
          const lazyStorage: ModelStorage = {
            size: (path) => target().size(path),
            read: (path) => target().read(path),
            write: (path) => target().write(path),
            remove: (path) => target().remove(path)
          };
          const result = await downloadEntry(entry, {
            fetch: options.fetch,
            storage: lazyStorage,
            assetsUrl: options.assetsUrl,
            signal: controller.signal,
            consent: async (prompt) => {
              const accepted = await askConsent(prompt);
              if (accepted) {
                cancelDownloadButton.hidden = false;
                await options.requestPersistence?.();
                opened ??= await options.openEntryStore!(entry, { create: true });
                if (opened === undefined) throw new Error("could not open model storage");
                store.set(entry.id, opened);
              }
              return accepted;
            },
            onProgress: ({ path, doneBytes, totalBytes }) => {
              progress.hidden = false;
              progress.value = Math.round((doneBytes / totalBytes) * 100);
              status.textContent = `Downloading ${path}: ${megabytes(doneBytes)} of ${megabytes(totalBytes)}`;
            }
          });
          progress.hidden = true;
          cancelDownloadButton.hidden = true;
          if (!result.installed) {
            status.textContent = "Download cancelled; nothing was fetched.";
            return;
          }
          installedIds.add(entry.id);
          renderModels();
          model.value = entry.id;
          await rebuildEngine();
          await refreshVoices();
        }
        await warm(entry);
      } catch (error) {
        progress.hidden = true;
        status.textContent = isDownloadCancelled(error)
          ? "Download cancelled; verified files are kept."
          : `failed: ${describeError(error)}`;
      } finally {
        cancelDownload = undefined;
        cancelDownloadButton.hidden = true;
        updateButtons();
      }
    })();
  });
}
