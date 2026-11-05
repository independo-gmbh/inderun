import {
  type NeuralSpeechAvailability,
  NeuralSpeechRuntimeError,
  type NeuralSpeechRuntime,
  type NeuralSpeechSynthesisInput,
  type PcmChunk
} from "./runtime.js";

export interface FixtureNeuralSpeechRuntimeOptions {
  /** Default `{ available: true }`. */
  availability?: NeuralSpeechAvailability;
  /** Default `{ available: true }`. */
  prepareResult?: NeuralSpeechAvailability;
  /** Synthetic duration per character of the sentence. Default 50. */
  msPerCharacter?: number;
  /** Duration of one chunk. Default 100. */
  chunkMs?: number;
  /** Wall delay before each chunk. Default 0. */
  delayMs?: number;
  /** Throw `NeuralSpeechRuntimeError("internal")` after this many chunks. */
  failAfterChunks?: number;
}

export interface FixtureNeuralSpeechRuntime extends NeuralSpeechRuntime {
  readonly synthesized: { text: string; locale: string; voiceId: string }[];
  readonly prepareCalls: number;
  readonly availabilityCalls: number;
}

const TONE_HZ = 440;
const AMPLITUDE = 0.2 * 32767; // about -14 dBFS

/**
 * Deterministic runtime for tests: a 440 Hz sine at -14 dBFS with phase continuous across the
 * chunks of one sentence, `msPerCharacter` times the sentence length long, in chunks of `chunkMs`.
 * The last chunk is partial when the duration is not a multiple of `chunkMs`.
 */
export function createFixtureNeuralSpeechRuntime(
  options: FixtureNeuralSpeechRuntimeOptions = {}
): FixtureNeuralSpeechRuntime {
  const msPerCharacter = options.msPerCharacter ?? 50;
  const chunkMs = options.chunkMs ?? 100;
  const delayMs = options.delayMs ?? 0;
  const synthesized: { text: string; locale: string; voiceId: string }[] = [];
  let prepareCalls = 0;
  let availabilityCalls = 0;

  async function* synthesize(input: NeuralSpeechSynthesisInput): AsyncGenerator<PcmChunk> {
    synthesized.push({ text: input.text, locale: input.locale, voiceId: input.voiceId });
    const sampleRate = input.modelPackage.speech?.sampleRate ?? 24000;
    const totalFrames = Math.round((input.text.length * msPerCharacter * sampleRate) / 1000);
    const chunkFrames = Math.max(1, Math.round((chunkMs * sampleRate) / 1000));

    let produced = 0;
    let chunkCount = 0;
    while (produced < totalFrames) {
      if (input.signal?.aborted) return;
      if (options.failAfterChunks !== undefined && chunkCount >= options.failAfterChunks) {
        throw new NeuralSpeechRuntimeError("internal", "fixture synthesis failed");
      }
      if (delayMs > 0) {
        await new Promise<void>((resolve) => setTimeout(resolve, delayMs));
        if (input.signal?.aborted) return;
      }
      const frames = Math.min(chunkFrames, totalFrames - produced);
      const samples = new Int16Array(frames);
      for (let i = 0; i < frames; i += 1) {
        samples[i] = Math.round(
          AMPLITUDE * Math.sin((2 * Math.PI * TONE_HZ * (produced + i)) / sampleRate)
        );
      }
      produced += frames;
      chunkCount += 1;
      yield { samples, sampleRate, isLast: produced >= totalFrames };
    }
  }

  return {
    synthesized,
    get prepareCalls() {
      return prepareCalls;
    },
    get availabilityCalls() {
      return availabilityCalls;
    },
    async availability() {
      availabilityCalls += 1;
      return options.availability ?? { available: true };
    },
    async prepare() {
      prepareCalls += 1;
      return options.prepareResult ?? { available: true };
    },
    synthesize
  };
}
