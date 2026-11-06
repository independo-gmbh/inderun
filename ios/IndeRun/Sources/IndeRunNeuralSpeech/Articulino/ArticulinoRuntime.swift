// Adapted from eigenhand/articulino-onnx, Apache License 2.0
// (https://huggingface.co/eigenhand/Articulino-DE-EN-Realtime-Stream-TTS-ONNX).

import Foundation
import IndeRunContracts

/// Options of an ``ArticulinoRuntime``.
public struct ArticulinoRuntimeOptions: Sendable {
    public let executor: any SpeechGraphExecutor
    public let files: any SpeechPackageFiles
    /// Default: Box-Muller over the system random number generator.
    public let noise: NoiseSource?
    /// Clamped to 0.7...1.6.
    public let speed: Float
    /// Silence appended after the sentence.
    public let pauseMs: Int
    /// Sentences with more letters are split before synthesis.
    public let maxLetters: Int

    public init(
        executor: any SpeechGraphExecutor,
        files: any SpeechPackageFiles,
        noise: NoiseSource? = nil,
        speed: Float = 1.0,
        pauseMs: Int = 150,
        maxLetters: Int = 180
    ) {
        self.executor = executor
        self.files = files
        self.noise = noise
        self.speed = speed
        self.pauseMs = pauseMs
        self.maxLetters = maxLetters
    }
}

/// The Articulino text-to-PCM pipeline over a ``SpeechGraphExecutor``: letters, the `text` graph,
/// durations, the `dit_step` flow steps, the `decoder` and the post-processing, one ``PcmChunk``
/// per sentence. The math lives in ``ArticulinoMath``; this type holds the loaded state (config,
/// voices) and the per-sentence orchestration.
///
/// Cancelling the consuming task, or abandoning the iteration, ends the stream between graph
/// calls without an error.
public final class ArticulinoRuntime: NeuralSpeechRuntime {
    private static let pipeline = "articulino"
    private static let roles = ["text", "dit_step", "decoder"]
    private static let voiceFormat = "inderun.articulino.voice/1"
    private static let voiceRanks: [(name: String, rank: Int)] = [
        ("voice_tokens", 3), ("voice_vector", 2), ("voice_cache", 6), ("prompt_latents", 3), ("letter_rate", 1)
    ]
    /// The slowest `speed` and the non-zero voice `letter_rate` band the runtime accepts.
    private static let minSpeed: Float = 0.7
    private static let letterRates: ClosedRange<Float> = 1 ... 100
    /// Largest element count of one tensor a pipeline allocates (the Kotlin array limit, on every SDK).
    private static let maxTensorElements = Int(Int32.max)

    /// The pre-split hook of every composed runtime that runs this pipeline: a grapheme frontend reads
    /// letters, so numbers, dates and abbreviations go through the shared core first; any other
    /// frontend gets the text unchanged.
    public static func normalizeText(_ modelPackage: ModelPackage, text: String, locale: String) -> String {
        guard modelPackage.speech?.frontend?.kind == .grapheme, isGerman(locale) else { return text }
        return SharedCoreSpeechText.normalize(text, locale: locale)
    }

    /// True when the language subtag of `locale` is `de` (case-insensitive, `-` or `_` separated), the
    /// core's own rule; other text never crosses the C string boundary, which cannot carry a NUL.
    private static func isGerman(_ locale: String) -> Bool {
        locale.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "_" })
            .first?.lowercased() == "de"
    }

    public func normalizeText(_ modelPackage: ModelPackage, text: String, locale: String) -> String {
        Self.normalizeText(modelPackage, text: text, locale: locale)
    }

    private struct Voice: Sendable {
        let voiceTokens: SpeechTensor
        let voiceVector: SpeechTensor
        let voiceCache: SpeechTensor
        let promptLatents: SpeechTensor
        let letterRate: Float
        /// Prompt frames P, read from `voice_cache`'s shape.
        let promptFrames: Int
    }

    private struct Prepared: Sendable {
        let config: ArticulinoConfig
        let voices: [String: Voice]
    }

    private enum Outcome: Sendable {
        case ready(Prepared)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private struct VoiceError: Error {
        let why: String
    }

    /// What the last prepare of a package left behind, and the prepare in flight. Concurrent
    /// sentences share one load.
    private actor State {
        private var current: (key: String, outcome: Outcome)?
        private var inflight: (key: String, task: Task<Outcome, Never>)?

        /// The remembered outcome of `key`, else a load. `reload: true` (prepare) loads again after a failed
        /// outcome but keeps a ready one; either way an in-flight load of the same key is joined.
        func outcome(for key: String, reload: Bool, load: @escaping @Sendable () async -> Outcome) async -> Outcome {
            if let current, current.key == key, !reload || current.outcome.isReady { return current.outcome }
            if let inflight {
                let finished = await inflight.task.value
                if inflight.key == key { return finished }
                return await outcome(for: key, reload: reload, load: load)
            }
            let task = Task { await load() }
            inflight = (key, task)
            let outcome = await task.value
            inflight = nil
            current = (key, outcome)
            return outcome
        }
    }

    private let options: ArticulinoRuntimeOptions
    private let noise: NoiseSource
    private let speed: Float
    private let state = State()

    public init(options: ArticulinoRuntimeOptions) {
        self.options = options
        self.noise = options.noise ?? ArticulinoMath.gaussianNoise
        self.speed = min(1.6, max(0.7, options.speed))
    }

    // MARK: NeuralSpeechRuntime

    public func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        check(modelPackage)
    }

    /// Idempotent on success: a package (`id@version`) already prepared is not loaded again; a failed one is.
    public func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        switch await outcome(modelPackage, reload: true) {
        case .ready: return NeuralSpeechAvailability(available: true)
        case let .failed(reason): return NeuralSpeechAvailability(available: false, reason: reason)
        }
    }

    public func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let chunk = try await self.synthesizeSentence(input) { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Availability and prepare

    private func check(_ modelPackage: ModelPackage) -> NeuralSpeechAvailability {
        Self.checkPackage(modelPackage)
    }

    /// The package metadata the pipeline needs (pipeline, `frontend.assets.config`, the three graph
    /// roles, a file per voice), checked without loading anything, so a composed runtime can refuse
    /// an incomplete package before it does expensive work of its own.
    package static func checkPackage(_ modelPackage: ModelPackage) -> NeuralSpeechAvailability {
        let speech = modelPackage.speech
        guard speech?.pipeline == Self.pipeline, let speech else {
            return NeuralSpeechAvailability(available: false, reason: "unsupported pipeline '\(speech?.pipeline ?? "")'")
        }
        guard speech.frontend?.assets?["config"] != nil else {
            return NeuralSpeechAvailability(available: false, reason: "pipeline config missing: speech.frontend.assets.config")
        }
        for role in Self.roles where speech.graphs[role] == nil {
            return NeuralSpeechAvailability(available: false, reason: "graph missing: \(role)")
        }
        for voice in speech.voices where voice.file == nil {
            return NeuralSpeechAvailability(available: false, reason: "voice file missing: \(voice.id)")
        }
        return NeuralSpeechAvailability(available: true)
    }

    private func outcome(_ modelPackage: ModelPackage, reload: Bool) async -> Outcome {
        await state.outcome(for: "\(modelPackage.id)@\(modelPackage.version ?? "")", reload: reload) { [self] in
            await load(modelPackage)
        }
    }

    private func load(_ modelPackage: ModelPackage) async -> Outcome {
        let check = check(modelPackage)
        guard check.available, let speech = modelPackage.speech, let configFile = speech.frontend?.assets?["config"] else {
            return .failed(check.reason ?? "unavailable")
        }
        do {
            let config = try ArticulinoConfig.parse(try await options.files.read(configFile))
            try await options.executor.load(graphs: speech.graphs.filter { Self.roles.contains($0.key) })
            var voices: [String: Voice] = [:]
            for voice in speech.voices {
                let bytes = try await options.files.read(voice.file ?? "")
                do {
                    voices[voice.id] = try parseVoice(bytes, latentDim: config.latentDim)
                } catch let error as VoiceError {
                    return .failed("voice file malformed: \(voice.id): \(error.why)")
                } catch let error as NeuralSpeechRuntimeError {
                    let prefix = "voice file malformed: "
                    return .failed(
                        error.message.hasPrefix(prefix)
                            ? "\(prefix)\(voice.id): \(error.message.dropFirst(prefix.count))"
                            : "\(error.message) (voice '\(voice.id)')"
                    )
                }
            }
            return .ready(Prepared(config: config, voices: voices))
        } catch let error as NeuralSpeechRuntimeError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func parseVoice(_ data: Data, latentDim: Int) throws -> Voice {
        let file = try Safetensors.parse(data)
        guard file.metadata["format"] == Self.voiceFormat else {
            throw VoiceError(why: "unexpected format '\(file.metadata["format"] ?? "")'")
        }
        for (name, rank) in Self.voiceRanks {
            guard let tensor = file.tensors[name] else { throw VoiceError(why: "missing tensor '\(name)'") }
            guard case .f32 = tensor.data else { throw VoiceError(why: "tensor '\(name)' is not f32") }
            guard tensor.shape.count == rank else {
                throw VoiceError(why: "tensor '\(name)' has rank \(tensor.shape.count), expected \(rank)")
            }
        }
        let promptLatents = file.tensors["prompt_latents"]!
        let voiceCache = file.tensors["voice_cache"]!
        guard promptLatents.shape[2] == latentDim else {
            throw VoiceError(why: "tensor 'prompt_latents' does not have \(latentDim) latent channels")
        }
        let letterRates = Self.floats(file.tensors["letter_rate"])
        guard let letterRate = letterRates.first, letterRates.count == 1 else {
            throw VoiceError(why: "tensor 'letter_rate' is not a scalar")
        }
        guard letterRate == 0 || Self.letterRates.contains(letterRate) else { throw VoiceError(why: "letter_rate out of range") }
        return Voice(
            voiceTokens: file.tensors["voice_tokens"]!,
            voiceVector: file.tensors["voice_vector"]!,
            voiceCache: voiceCache,
            promptLatents: promptLatents,
            letterRate: letterRate,
            promptFrames: voiceCache.shape[4]
        )
    }

    // MARK: Synthesis

    private static func floats(_ tensor: SpeechTensor?) -> [Float] {
        if case let .f32(values)? = tensor?.data { return values }
        return []
    }

    /// The f32 elements of an output of `role`, which must number `count`.
    private static func requireFloats(_ tensor: SpeechTensor?, _ what: String, role: String, count: Int) throws -> [Float] {
        guard case let .f32(values)? = tensor?.data else {
            throw NeuralSpeechRuntimeError(kind: .internalFailure, message: "pipeline failed: \(role).\(what) is not an f32 tensor")
        }
        guard values.count == count else {
            throw NeuralSpeechRuntimeError(
                kind: .internalFailure,
                message: "pipeline failed: \(role).\(what) has \(values.count) elements, expected \(count)"
            )
        }
        return values
    }

    /// The most frames a piece of `letters` letters can span once config and voice are range-checked: every
    /// duration is at most `max(max_duration_units, 100 / letter_rate) / speed`, plus the prompt placeholder;
    /// and no tensor of the piece may outgrow ``maxTensorElements``.
    private static func maxFrames(letters: Int, promptFrames: Int, lead: Int, stride: Int, config: ArticulinoConfig) -> Int {
        let perLetter = Double(max(config.maxDurationUnits, 100 / letterRates.lowerBound) / minSpeed)
        let byDurations = Double(promptFrames) + (Double(letters) * perLetter / Double(config.durationUnitsPerFrame)).rounded(.up) + 1
        let widest = max(config.samplesPerFrame, config.latentDim, stride, 1)
        let byBuffers = promptFrames - lead + maxTensorElements / widest
        return min(byBuffers, Int(min(byDurations, Double(byBuffers))))
    }

    /// The sentence's one chunk, or `nil` when the task was cancelled between graph calls.
    private func synthesizeSentence(_ input: NeuralSpeechSynthesisInput) async throws -> PcmChunk? {
        let prepared: Prepared
        switch await outcome(input.modelPackage, reload: false) {
        case let .ready(value): prepared = value
        case let .failed(reason): throw NeuralSpeechRuntimeError(kind: .unavailable, message: reason)
        }
        let config = prepared.config
        let language = input.locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        guard let languageId = config.languages[language] else {
            throw NeuralSpeechRuntimeError(kind: .capability, message: "locale unsupported: \(input.locale)")
        }
        guard let voice = prepared.voices[input.voiceId] else {
            throw NeuralSpeechRuntimeError(kind: .capability, message: "voice not found: \(input.voiceId)")
        }

        let normalized = ArticulinoMath.normalizeLetters(input.text, charset: config.charset)
        var body: [Float] = []
        do {
            let pieces = normalized.isEmpty ? [] : ArticulinoMath.splitLongSentence(normalized, maxLetters: options.maxLetters)
            for piece in pieces {
                if Task.isCancelled { return nil }
                guard let audio = try await synthesizePiece(piece, languageId: languageId, config: config, voice: voice) else {
                    return nil
                }
                body += audio
            }
        } catch let error as NeuralSpeechRuntimeError {
            throw error
        } catch is CancellationError {
            return nil
        } catch {
            throw NeuralSpeechRuntimeError(
                kind: .internalFailure, message: "pipeline failed: \(String(describing: error))", originalError: error
            )
        }
        if Task.isCancelled { return nil }
        let padded = ArticulinoMath.padSilence(body, pauseMs: options.pauseMs, sampleRate: config.sampleRate)
        return PcmChunk(samples: ArticulinoMath.toInt16(padded), sampleRate: config.sampleRate, isLast: true)
    }

    /// One piece through the graphs; `nil` when cancelled between graph calls.
    private func synthesizePiece(_ text: String, languageId: Int, config: ArticulinoConfig, voice: Voice) async throws -> [Float]? {
        let letters = ArticulinoMath.encodeLetters(text, language: languageId, config: config)
        if letters.ids.isEmpty { return [] }
        let count = letters.ids.count + 1
        let textIds = [0] + letters.ids
        let mask: [Int64] = textIds.indices.map { $0 == 0 ? 0 : 1 }

        if Task.isCancelled { return nil }
        let encoded = try await options.executor.run(role: "text", inputs: [
            "text_ids": SpeechTensor(shape: [1, count], data: .i64(textIds.map(Int64.init))),
            "language": SpeechTensor(shape: [1, count], data: .i64([Int64(languageId)] + letters.languages.map(Int64.init))),
            "text_mask": SpeechTensor(shape: [1, count], data: .i64(mask)),
            "voice_vector": voice.voiceVector
        ])
        let stride = max(0, encoded["text_features"]?.shape.last ?? 0)
        let (featureCount, overflow) = count.multipliedReportingOverflow(by: stride)
        let features = try Self.requireFloats(
            encoded["text_features"], "text_features", role: "text", count: overflow ? Int.max : featureCount
        )
        let logDurations = try Self.requireFloats(encoded["log_durations"], "log_durations", role: "text", count: count)

        let units = config.durationUnitsPerFrame
        var d = ArticulinoMath.clampDurations(logDurations: logDurations, mask: mask, speed: speed, maxUnits: config.maxDurationUnits)
        if voice.letterRate > 0 {
            ArticulinoMath.equalizeLetterRate(&d, ids: textIds, charset: config.charset, start: 1, target: voice.letterRate * speed)
        }
        d[0] = Float(units * voice.promptFrames)
        guard d.allSatisfy(\.isFinite) else {
            throw NeuralSpeechRuntimeError(
                kind: .internalFailure, message: "pipeline failed: text.log_durations yields non-finite durations"
            )
        }
        let lead = min(voice.promptLatents.shape[1], config.decoderLeadInFrames)
        let frames = ArticulinoMath.frameCount(d, units: units)
        let limit = Self.maxFrames(letters: letters.ids.count, promptFrames: voice.promptFrames, lead: lead, stride: stride, config: config)
        guard frames <= limit else {
            throw NeuralSpeechRuntimeError(
                kind: .internalFailure, message: "pipeline failed: text.log_durations yields \(frames) frames, more than \(limit)"
            )
        }
        let newFrames = frames - voice.promptFrames
        if newFrames <= 0 { return [] }
        let condition = ArticulinoMath.frameCondition(
            features: features, stride: stride, durations: d, first: voice.promptFrames, frames: frames, units: units
        )
        let frameCond = SpeechTensor(shape: [1, newFrames, stride], data: .f32(condition))

        let latentShape = [1, newFrames, config.latentDim]
        let latentCount = newFrames * config.latentDim
        var x = noise(latentCount)
        var x1 = x
        for (k, t) in config.times.enumerated() {
            if Task.isCancelled { return nil }
            let out = try await options.executor.run(role: "dit_step", inputs: [
                "x": SpeechTensor(shape: latentShape, data: .f32(x)),
                "t": SpeechTensor(shape: [1], data: .f32([t])),
                "frame_cond": frameCond,
                "voice_tokens": voice.voiceTokens,
                "voice_vector": voice.voiceVector,
                "voice_cache": voice.voiceCache
            ])
            let hasNext = k + 1 < config.times.count
            let step = ArticulinoMath.flowStep(
                x: x, t: t, velocity: try Self.requireFloats(out["velocity"], "velocity", role: "dit_step", count: latentCount),
                nextT: hasNext ? config.times[k + 1] : nil, nextNoise: hasNext ? noise(latentCount) : nil
            )
            x1 = step.x1
            if let next = step.next { x = next }
        }

        let prompt = Self.floats(voice.promptLatents)
        let latents = Array(prompt.suffix(lead * config.latentDim)) + x1

        if Task.isCancelled { return nil }
        let decoded = try await options.executor.run(role: "decoder", inputs: [
            "latents": SpeechTensor(shape: [1, lead + newFrames, config.latentDim], data: .f32(latents))
        ])
        let waveform = try Self.requireFloats(
            decoded["waveform"], "waveform", role: "decoder", count: (lead + newFrames) * config.samplesPerFrame
        )
        return ArticulinoMath.shapeWaveform(waveform, leadSamples: lead * config.samplesPerFrame, config: config)
    }
}
