import {
  SystemSpeechRuntimeError,
  type SystemSpeechRuntime,
  type SystemSpeechUtterance,
  type SystemSpeechVoice
} from "./runtime.js";

/** The parts of `SpeechSynthesisVoice` this runtime reads. */
export interface BrowserSpeechVoice {
  voiceURI: string;
  name?: string;
  lang: string;
  localService?: boolean;
  default?: boolean;
}

/** The parts of `SpeechSynthesisUtterance` this runtime sets. */
export interface BrowserSpeechUtterance {
  lang: string;
  voice: BrowserSpeechVoice | null;
  onstart: (() => void) | null;
  onend: (() => void) | null;
  onerror: ((event: { error?: string }) => void) | null;
}

/** The parts of `window.speechSynthesis` this runtime calls. */
export interface BrowserSpeechSynthesis {
  speaking?: boolean;
  pending?: boolean;
  getVoices(): BrowserSpeechVoice[];
  speak(utterance: BrowserSpeechUtterance): void;
  cancel(): void;
  addEventListener?(type: "voiceschanged", listener: () => void): void;
  removeEventListener?(type: "voiceschanged", listener: () => void): void;
}

/** Options for {@link createBrowserSpeechRuntime}. */
export interface BrowserSpeechRuntimeOptions {
  /** The speech API. Defaults to the global one, read on each call. */
  synthesis?: () => BrowserSpeechSynthesis | undefined;
  /** Builds an utterance. Defaults to the global `SpeechSynthesisUtterance`. */
  createUtterance?: (text: string) => BrowserSpeechUtterance;
  /** How long to wait for `voiceschanged` when the list starts empty. Defaults to 1000 ms. */
  voiceWaitMs?: number;
  /** How long an utterance may take to start. Defaults to 15000 ms. */
  startTimeoutMs?: number;
  /** How often to look at a busy queue, which has no event for going idle. Defaults to 100 ms. */
  idlePollMs?: number;
  /** How long `prepare` waits for the browser to list voices. Defaults to 30000 ms. */
  voiceLoadMs?: number;
}

const DEFAULT_VOICE_WAIT_MS = 1000;
const DEFAULT_START_TIMEOUT_MS = 15_000;
const DEFAULT_IDLE_POLL_MS = 100;
const DEFAULT_VOICE_LOAD_MS = 30_000;

/** Reads the globals structurally; `lib.dom`'s event-typed handlers are wider than these. */
const speechGlobals = globalThis as unknown as {
  speechSynthesis?: BrowserSpeechSynthesis;
  SpeechSynthesisUtterance?: new (text: string) => BrowserSpeechUtterance;
};

/**
 * The default runtime, over the Web Speech API.
 *
 * Browsers fill the voice list asynchronously, so the first empty read waits a bounded time for
 * `voiceschanged`; a browser that never fires it ends up with no voices rather than a hang. Later
 * reads do not wait, because the capability check runs on every request, text included.
 *
 * An utterance that never starts fails after a bound.
 *
 * `speechSynthesis` is one queue per page and `cancel()` empties all of it, with no way to remove
 * one utterance. So a caller waits in {@link SystemSpeechRuntime.whenIdle} instead of queueing
 * behind other speech, which is what makes `cancel()` here reach only this runtime's utterance.
 * Speech queued behind it is lost to that cancel: see
 * `docs/architecture/system-speech-provider-family.md`.
 */
export function createBrowserSpeechRuntime(
  options: BrowserSpeechRuntimeOptions = {}
): SystemSpeechRuntime {
  const synthesis = options.synthesis ?? (() => speechGlobals.speechSynthesis);
  const createUtterance =
    options.createUtterance ??
    ((text: string) => new speechGlobals.SpeechSynthesisUtterance!(text));
  const voiceWaitMs = options.voiceWaitMs ?? DEFAULT_VOICE_WAIT_MS;
  const startTimeoutMs = options.startTimeoutMs ?? DEFAULT_START_TIMEOUT_MS;
  const idlePollMs = options.idlePollMs ?? DEFAULT_IDLE_POLL_MS;
  const voiceLoadMs = options.voiceLoadMs ?? DEFAULT_VOICE_LOAD_MS;
  let waitedForVoices = false;

  const listed = async (api: BrowserSpeechSynthesis): Promise<BrowserSpeechVoice[]> => {
    const voices = api.getVoices();
    if (voices.length > 0 || waitedForVoices || api.addEventListener === undefined) return voices;
    waitedForVoices = true;
    await new Promise<void>((resolve) => {
      const done = () => {
        clearTimeout(timer);
        api.removeEventListener?.("voiceschanged", done);
        resolve();
      };
      const timer = setTimeout(done, voiceWaitMs);
      api.addEventListener?.("voiceschanged", done);
    });
    return api.getVoices();
  };

  return {
    availability() {
      const hasApi =
        synthesis() !== undefined &&
        (options.createUtterance !== undefined ||
          speechGlobals.SpeechSynthesisUtterance !== undefined);
      return hasApi
        ? { kind: "available" }
        : { kind: "api_missing", reason: "This browser has no speechSynthesis API." };
    },

    async voices() {
      const api = synthesis();
      if (api === undefined) return [];
      const voices = await listed(api);
      // A stable sort, so browser order decides among equals and the planner's tie-break
      // prefers what the browser calls local, then its default.
      return [...voices]
        .sort(
          (a, b) =>
            Number(b.localService === true) - Number(a.localService === true) ||
            Number(b.default === true) - Number(a.default === true)
        )
        .map((voice): SystemSpeechVoice => ({
          uri: voice.voiceURI,
          ...(voice.name ? { name: voice.name } : {}),
          locale: voice.lang,
          ...(voice.localService !== undefined ? { localService: voice.localService } : {})
        }));
    },

    whenVoicesListed(signal?: AbortSignal) {
      const api = synthesis();
      if (api === undefined) return Promise.resolve(false);
      if (api.getVoices().length > 0) return Promise.resolve(true);
      return new Promise<boolean>((resolve) => {
        const finish = () => {
          clearTimeout(timer);
          clearInterval(poll);
          api.removeEventListener?.("voiceschanged", check);
          signal?.removeEventListener("abort", finish);
          resolve(api.getVoices().length > 0);
        };
        const check = () => {
          if (api.getVoices().length > 0) finish();
        };
        const timer = setTimeout(finish, voiceLoadMs);
        // Not every browser fires `voiceschanged`, so the list is read as well.
        const poll = setInterval(check, idlePollMs);
        api.addEventListener?.("voiceschanged", check);
        signal?.addEventListener("abort", finish, { once: true });
        if (signal?.aborted === true) finish();
      });
    },

    whenIdle(signal?: AbortSignal) {
      const api = synthesis()!;
      return new Promise<void>((resolve) => {
        let timer: ReturnType<typeof setTimeout> | undefined;
        const done = () => {
          clearTimeout(timer);
          signal?.removeEventListener("abort", done);
          resolve();
        };
        const check = () => {
          const busy = api.speaking === true || api.pending === true;
          if (busy && signal?.aborted !== true) timer = setTimeout(check, idlePollMs);
          else done();
        };
        signal?.addEventListener("abort", done, { once: true });
        check();
      });
    },

    speak(input: SystemSpeechUtterance, signal?: AbortSignal) {
      const api = synthesis()!;
      return new Promise((resolve, reject) => {
        if (signal?.aborted === true) {
          resolve({ stopped: true });
          return;
        }
        const uri = input.voice?.uri;
        const voice = api.getVoices().find((listed) => listed.voiceURI === uri);
        if (uri !== undefined && voice === undefined) {
          reject(
            new SystemSpeechRuntimeError("synthesis_failed", "The voice is no longer available.")
          );
          return;
        }
        const utterance = createUtterance(input.text);
        utterance.lang = input.locale;
        utterance.voice = voice ?? null;

        let settled = false;
        let startedAt: number | undefined;
        const settle = (finish: () => void) => {
          if (settled) return;
          settled = true;
          clearTimeout(startTimer);
          signal?.removeEventListener("abort", stop);
          finish();
        };
        const startTimer = setTimeout(() => {
          settle(() =>
            reject(
              new SystemSpeechRuntimeError(
                "synthesis_failed",
                "Speech synthesis did not start within the timeout."
              )
            )
          );
          api.cancel();
        }, startTimeoutMs);
        const stop = () => {
          // Settle first: the `canceled` error cancel() raises must not read as a failure.
          settle(() => resolve({ stopped: true }));
          api.cancel();
        };

        signal?.addEventListener("abort", stop, { once: true });
        utterance.onstart = () => {
          startedAt = Date.now();
          clearTimeout(startTimer);
        };
        utterance.onend = () =>
          settle(() =>
            resolve(startedAt !== undefined ? { durationMs: Date.now() - startedAt } : {})
          );
        utterance.onerror = (event) =>
          settle(() =>
            reject(
              new SystemSpeechRuntimeError(
                event.error === "not-allowed" ? "not_allowed" : "synthesis_failed",
                `Speech synthesis failed: ${event.error ?? "unknown error"}.`
              )
            )
          );

        api.speak(utterance);
      });
    }
  };
}
