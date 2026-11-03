import {
  generateSpeech,
  IndeRunException,
  listVoices,
  prepare,
  speak,
  type IndeRunApi,
  type ProviderCapabilitySnapshot,
  type SpeechVoiceInfo
} from "@independo/inderun-web";

const LOCALES: { tag: string; label: string }[] = [
  { tag: "de-AT", label: "Deutsch (Österreich)" },
  { tag: "de-DE", label: "Deutsch (Deutschland)" },
  { tag: "en-US", label: "English (US)" }
];

/**
 * Which registered providers can play speech and which can return audio on this host right now:
 * the descriptor says what a provider can deliver, and the live check can take speech away, as it
 * does when no voice is installed. Playback runs as a stream, so a host that takes streaming away
 * takes playback with it.
 */
function speechDeliveries(snapshots: ProviderCapabilitySnapshot[]): {
  playback: string[];
  artifact: string[];
} {
  const playback: string[] = [];
  const artifact: string[] = [];
  for (const { providerId, descriptor, capabilities } of snapshots) {
    if (!capabilities.available) continue;
    const live = capabilities.taskCapabilities?.find((entry) => entry.kind === "text_to_speech");
    if (live?.available === false) continue;
    const task = descriptor.taskCapabilities?.find((entry) => entry.kind === "text_to_speech");
    const deliveries = new Set(task?.outputs.map((output) => output.delivery));
    const streams = (live?.streamingAvailable ?? capabilities.streamingAvailable) !== false;
    if (deliveries.has("playback") && streams) playback.push(providerId);
    if (deliveries.has("artifact")) artifact.push(providerId);
  }
  return { playback, artifact };
}

/**
 * A small panel over the primary speech API: this file never touches `speechSynthesis`, so what it
 * shows is what any application gets. Whether audio can be retrieved comes from capability
 * introspection, not from knowing which provider runs here. The status region is a live region,
 * so a screen reader announces each ending.
 */
export function mountSpeechPanel(root: HTMLElement, inderun: IndeRunApi): void {
  root.innerHTML = `
    <section class="panel" aria-labelledby="speech-heading">
      <h2 id="speech-heading">Speech</h2>
      <label for="speech-text">Text to speak</label>
      <textarea id="speech-text" rows="2">Der Bus kommt in fünf Minuten.</textarea>
      <label for="speech-locale">Language</label>
      <select id="speech-locale"></select>
      <label for="speech-voice">Voice</label>
      <select id="speech-voice"></select>
      <div class="actions">
        <button id="speech-speak" type="button">Speak</button>
        <button id="speech-stop" type="button" disabled>Stop</button>
        <button id="speech-generate" type="button" disabled aria-describedby="speech-delivery">
          Generate audio
        </button>
      </div>
      <p id="speech-voices"></p>
      <p id="speech-delivery"></p>
      <p id="speech-status" role="status" aria-live="polite"></p>
      <audio id="speech-audio" controls hidden></audio>
    </section>`;

  const text = root.querySelector<HTMLTextAreaElement>("#speech-text")!;
  const locale = root.querySelector<HTMLSelectElement>("#speech-locale")!;
  const voice = root.querySelector<HTMLSelectElement>("#speech-voice")!;
  const speakButton = root.querySelector<HTMLButtonElement>("#speech-speak")!;
  const stopButton = root.querySelector<HTMLButtonElement>("#speech-stop")!;
  const generateButton = root.querySelector<HTMLButtonElement>("#speech-generate")!;
  const voices = root.querySelector<HTMLElement>("#speech-voices")!;
  const delivery = root.querySelector<HTMLElement>("#speech-delivery")!;
  const status = root.querySelector<HTMLElement>("#speech-status")!;
  const audio = root.querySelector<HTMLAudioElement>("#speech-audio")!;

  for (const { tag, label } of LOCALES) {
    const option = document.createElement("option");
    option.value = tag;
    option.textContent = label;
    locale.append(option);
  }
  locale.value = "de-DE";

  let available: SpeechVoiceInfo[] = [];
  const showVoices = async () => {
    available = await listVoices(inderun, { locale: locale.value });
    voices.textContent = `${available.length} voice(s) available for ${locale.value}.`;
    const option = (label: string, value: string) => {
      const element = document.createElement("option");
      element.value = value;
      element.textContent = label;
      return element;
    };
    voice.replaceChildren(option("Automatic", ""));
    const seen = new Map<string, number>();
    available.forEach((entry, index) => {
      const name = `${entry.name ?? entry.id ?? "Voice"} (${entry.locale})`;
      const count = (seen.get(name) ?? 0) + 1;
      seen.set(name, count);
      // Names repeat, so a repeated one gets a number.
      voice.append(option(count === 1 ? name : `${name} ${count}`, String(index)));
    });
    // Optional: without this the first speak() would wait for the browser by itself.
    void prepare(inderun, { tasks: ["text_to_speech"], locale: locale.value });
  };
  locale.addEventListener("change", () => void showVoices());
  void showVoices();

  let canGenerate = false;
  void (async () => {
    const { playback, artifact } = speechDeliveries(await inderun.checkCapabilities());
    canGenerate = artifact.length > 0;
    generateButton.disabled = !canGenerate;
    delivery.textContent = [
      `Plays speech: ${playback.join(", ") || "no provider"}.`,
      canGenerate
        ? `Returns audio: ${artifact.join(", ")}.`
        : "Returns audio: no provider here; speech is playback-only on this platform."
    ].join(" ");
  })();

  let stop: (() => void) | undefined;
  let stopPressedAt: number | undefined;
  stopButton.addEventListener("click", () => {
    stopPressedAt ??= performance.now();
    stop?.();
  });

  speakButton.addEventListener("click", () => {
    void (async () => {
      speakButton.disabled = true;
      generateButton.disabled = true;
      stopPressedAt = undefined;
      status.textContent = "Speaking…";
      try {
        const picked = voice.value === "" ? undefined : available[Number(voice.value)];
        const playback = await speak(inderun, {
          text: text.value,
          locale: locale.value,
          ...(picked !== undefined ? { voice: picked } : {})
        });
        stop = () => playback.cancel("stopped from the demo");
        stopButton.disabled = false;
        // Stop takes focus, so a keyboard user can stop with one key press.
        stopButton.focus();
        const { finishReason, speech, provenance, firstAudioMs } = await playback.result;
        const parts = [
          finishReason,
          speech?.locale ?? locale.value,
          speech?.voice?.name,
          provenance?.providerId,
          provenance?.locality,
          firstAudioMs !== undefined ? `first word ${Math.round(firstAudioMs)} ms` : undefined,
          stopPressedAt !== undefined
            ? `stopped in ${Math.round(performance.now() - stopPressedAt)} ms`
            : undefined
        ];
        status.textContent = parts.filter((part) => part !== undefined).join(" · ");
      } catch (error) {
        status.textContent =
          error instanceof IndeRunException
            ? `failed: ${error.errorClass}: ${error.message}`
            : `failed: ${String(error)}`;
      } finally {
        const hadFocus = document.activeElement === stopButton;
        stop = undefined;
        speakButton.disabled = false;
        stopButton.disabled = true;
        generateButton.disabled = !canGenerate;
        if (hadFocus) speakButton.focus();
      }
    })();
  });

  // Silent: renders the text to an artifact, reads it whole, releases it, and offers the copy
  // through an <audio> element. Reached only when a registered provider returns audio.
  let audioUrl: string | undefined;
  generateButton.addEventListener("click", () => {
    void (async () => {
      speakButton.disabled = true;
      generateButton.disabled = true;
      status.textContent = "Generating audio…";
      try {
        const picked = voice.value === "" ? undefined : available[Number(voice.value)];
        const generated = await generateSpeech(inderun, {
          text: text.value,
          locale: locale.value,
          ...(picked !== undefined ? { voice: picked } : {})
        });
        const chunks: Uint8Array[] = [];
        try {
          for (let offset = 0; ;) {
            const chunk = await inderun.readArtifact({ artifactId: generated.artifact.id, offset });
            chunks.push(chunk.bytes);
            offset += chunk.bytes.length;
            if (chunk.done) break;
          }
        } finally {
          await inderun.disposeArtifact(generated.artifact);
        }
        if (audioUrl !== undefined) URL.revokeObjectURL(audioUrl);
        audioUrl = URL.createObjectURL(
          new Blob(chunks as BlobPart[], { type: generated.artifact.mediaType })
        );
        audio.src = audioUrl;
        audio.hidden = false;
        const bytes = chunks.reduce((total, chunk) => total + chunk.length, 0);
        const duration = generated.artifact.durationMs;
        status.textContent = [
          generated.artifact.mediaType,
          `${bytes} bytes`,
          duration !== undefined ? `${Math.round(duration)} ms of audio` : undefined,
          generated.provenance?.providerId,
          generated.provenance?.locality
        ]
          .filter((part) => part !== undefined)
          .join(" · ");
      } catch (error) {
        status.textContent =
          error instanceof IndeRunException
            ? `failed: ${error.errorClass}: ${error.message}`
            : `failed: ${String(error)}`;
      } finally {
        speakButton.disabled = false;
        generateButton.disabled = !canGenerate;
      }
    })();
  });
}
