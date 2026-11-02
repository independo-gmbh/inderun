import {
  IndeRunException,
  listVoices,
  prepare,
  speak,
  type IndeRunApi,
  type SpeechVoiceInfo
} from "@independo/inderun-web";

const LOCALES: { tag: string; label: string }[] = [
  { tag: "de-AT", label: "Deutsch (Österreich)" },
  { tag: "de-DE", label: "Deutsch (Deutschland)" },
  { tag: "en-US", label: "English (US)" }
];

/**
 * A small panel over the primary speech API: this file never touches `speechSynthesis`, so what it
 * shows is what any application gets. The status region is a live region, so a screen reader
 * announces each ending.
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
      </div>
      <p id="speech-voices"></p>
      <p id="speech-status" role="status" aria-live="polite"></p>
    </section>`;

  const text = root.querySelector<HTMLTextAreaElement>("#speech-text")!;
  const locale = root.querySelector<HTMLSelectElement>("#speech-locale")!;
  const voice = root.querySelector<HTMLSelectElement>("#speech-voice")!;
  const speakButton = root.querySelector<HTMLButtonElement>("#speech-speak")!;
  const stopButton = root.querySelector<HTMLButtonElement>("#speech-stop")!;
  const voices = root.querySelector<HTMLElement>("#speech-voices")!;
  const status = root.querySelector<HTMLElement>("#speech-status")!;

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

  let stop: (() => void) | undefined;
  stopButton.addEventListener("click", () => stop?.());

  speakButton.addEventListener("click", () => {
    void (async () => {
      speakButton.disabled = true;
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
        const { finishReason, speech, provenance } = await playback.result;
        const spoken = [speech?.locale ?? locale.value, speech?.voice?.name]
          .filter((part) => part !== undefined)
          .join(" · ");
        status.textContent = `${finishReason} · ${spoken} · ${provenance?.providerId} · ${provenance?.locality}`;
      } catch (error) {
        status.textContent =
          error instanceof IndeRunException
            ? `failed: ${error.errorClass}: ${error.message}`
            : `failed: ${String(error)}`;
      } finally {
        stop = undefined;
        speakButton.disabled = false;
        stopButton.disabled = true;
      }
    })();
  });
}
