/** What a speech runtime observed about the host. */
export type SystemSpeechAvailability =
  { kind: "available" } | { kind: "api_missing"; reason: string };

/**
 * A voice the runtime can use. `uri` is the id the catalog lists it under (ADR 018).
 * `localService` is the browser's own claim, absent where it makes none.
 */
export interface SystemSpeechVoice {
  uri: string;
  name?: string;
  locale: string;
  localService?: boolean;
}

/** One utterance handed to a runtime. */
export interface SystemSpeechUtterance {
  text: string;
  locale: string;
  /** Absent lets the browser choose for `locale`. */
  voice?: SystemSpeechVoice;
}

/** Why a runtime could not finish an utterance. */
export type SystemSpeechRuntimeErrorKind = "not_allowed" | "synthesis_failed";

/** A runtime failure the provider maps onto the error taxonomy. */
export class SystemSpeechRuntimeError extends Error {
  constructor(
    readonly kind: SystemSpeechRuntimeErrorKind,
    message: string
  ) {
    super(message);
    this.name = "SystemSpeechRuntimeError";
  }
}

/**
 * The seam around the browser's speech API, so the provider's lifecycle runs in tests without one.
 */
export interface SystemSpeechRuntime {
  /** Never throws: an unsupported browser is an answer, not a failure. */
  availability(): SystemSpeechAvailability;
  /** Every voice right now, best guess at on-device first, then the default. Never throws. */
  voices(): Promise<SystemSpeechVoice[]>;
  /** Resolves `true` once the browser lists voices, or `false` at its bound or on `signal`. */
  whenVoicesListed(signal?: AbortSignal): Promise<boolean>;
  /**
   * Resolves once nothing is speaking or queued, or when `signal` fires. An utterance cannot leave
   * the shared queue on its own, so one that is never queued behind other speech can still be
   * stopped without touching that speech.
   */
  whenIdle(signal?: AbortSignal): Promise<void>;
  /**
   * Speaks and resolves once it has finished, with how long it played and how long the first
   * word took to start, when known. Resolves with `{ stopped: true }` when `signal` stopped it,
   * and rejects only with a {@link SystemSpeechRuntimeError}.
   */
  speak(
    utterance: SystemSpeechUtterance,
    signal?: AbortSignal
  ): Promise<{ stopped?: boolean; durationMs?: number; firstAudioMs?: number }>;
}
