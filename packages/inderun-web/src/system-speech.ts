/**
 * Provider-specific entry point for the Web member of the system speech provider family.
 *
 * Kept out of the unified SDK index (`@independo/inderun-web`) so the top-level surface stays
 * provider-agnostic. Import from `@independo/inderun-web/system-speech` when registering the
 * adapter manually or when implementing a custom `SystemSpeechRuntime`; most browser apps should
 * pass `systemSpeech` to `createIndeRunWeb` from the main entry point instead.
 */

/** The adapter itself, plus the default id the router plans against. */
export {
  DEFAULT_SYSTEM_SPEECH_WEB_PROVIDER_ID,
  SystemSpeechWebProvider,
  type SystemSpeechProviderOptions
} from "./providers/system-speech/provider.js";

/** The runtime seam. */
export {
  SystemSpeechRuntimeError,
  type SystemSpeechAvailability,
  type SystemSpeechRuntime,
  type SystemSpeechRuntimeErrorKind,
  type SystemSpeechUtterance,
  type SystemSpeechVoice
} from "./providers/system-speech/runtime.js";

/** The default runtime, over the Web Speech API. */
export {
  createBrowserSpeechRuntime,
  type BrowserSpeechRuntimeOptions,
  type BrowserSpeechSynthesis,
  type BrowserSpeechUtterance,
  type BrowserSpeechVoice
} from "./providers/system-speech/browser-runtime.js";
