import Foundation
import IndeRunContracts
import IndeRunCore

/// Configuration for ``NeuralSpeechProvider``.
public struct NeuralSpeechProviderOptions: Sendable {
    /// Defaults to `"\(NeuralSpeechProvider.defaultId):\(modelPackage.id)"`, so one application can
    /// register one provider per model without clashing ids.
    public let id: String?
    /// The speech model package: its `speech` block names the pipeline, graphs and voices.
    public let modelPackage: ModelPackage
    /// Executes the package. Required: no default runtime ships yet.
    public let runtime: any NeuralSpeechRuntime
    /// Bounds the synthesis until the run commits: the wait for the first chunk when playing, the
    /// whole synthesis up to `finish()` when writing an artifact. A request's `constraints.timeoutMs`
    /// wins; zero or less is unbounded.
    public let timeout: Duration?

    public init(id: String? = nil, modelPackage: ModelPackage, runtime: any NeuralSpeechRuntime, timeout: Duration? = nil) {
        self.id = id
        self.modelPackage = modelPackage
        self.runtime = runtime
        self.timeout = timeout
    }
}

/// Text-to-speech with a developer-supplied neural speech model, synthesized in-process by a
/// ``NeuralSpeechRuntime`` and played through the host's `audioOutput` or returned as an
/// `audio/wav` artifact. Mirrors `NeuralSpeechWebProvider`.
///
/// Playback: the provider takes its turn (one utterance at a time per instance, first in first
/// out; a call cancelled while waiting leaves the queue and plays nothing), checks the host has an
/// `audioOutput` (`audio_output_unavailable`) and that the bound voice is one of the package's
/// (`voice_not_available`), loads the model, splits the text into sentences and opens one output
/// session. It then synthesizes sentence by sentence and commits on the first chunk, immediately
/// before the first `write`; a cancel before that point ends quietly with nothing written. After
/// commit, a cancel stops the session (buffered audio is discarded) and stops consuming the
/// runtime, and any error ends the run without fallback. A normal end drains, then stops. The
/// session is stopped on every exit. Chunks must carry the package's sample rate: it never
/// resamples. See `playSentences`.
///
/// Artifact: the same checks without the audio output. PCM is buffered in memory; when the next
/// chunk would make the WAV exceed ``maxArtifactBytes``, synthesis stops and the run fails
/// uncommitted with `artifact_too_large`. Otherwise the WAV is written once and `finish()` commits.
/// See `writeArtifact`.
///
/// Timing: `firstChunkMs`, `firstAudioMs` and `durationMs` count from the moment the request
/// arrived (`receivedAt`), before the turn wait. `firstAudioMs` = (instant before `open()` was
/// called − `receivedAt`) + `session.firstAudioMs()`, which every host measures from the start of
/// its `open()`, so a slow open is counted once; it is absent when the session reports none.
///
/// Cancellation is `hard`: audio stops at once; residual compute is bounded to the in-flight
/// sentence and is never audible. It is `Task` cancellation: `stream` cancels its task when the
/// engine's token fires, `run` honours the caller's. A cancel stops the session directly, also while
/// a `write` waits on backpressure or `drain` waits for buffered audio to play; the stream then ends
/// quietly, because the engine owns the `cancelled` terminal.
///
/// Timeout: the budget (a request's `constraints.timeoutMs`, else `timeout`; zero or less is
/// unbounded) bounds the time until the run commits, counted from the start of synthesis. Playback:
/// it bounds the wait for the first chunk only; after commit nothing times out, and a runtime that
/// stalls is ended only by a cancel, as with the system speech providers. Artifact: it bounds the
/// whole synthesis, across sentences, up to `finish()`: one absolute deadline, checked again before
/// the artifact is created and immediately before `finish()`; past it, the writer is aborted.
/// Expiry throws `Timeout` before commit, so the run can fall back; the pull is cancelled, so a
/// runtime whose stream honours cancellation returns at once, while one stuck in a synchronous call
/// is waited for until that call ends.
public final class NeuralSpeechProvider: StreamingProviderAdapter, PreparableProviderAdapter, Sendable {
    /// Default provider id of the Apple neural speech provider; an instance composes
    /// `<defaultId>:<modelPackage.id>`.
    public static let defaultId = "local.onnx.speech.apple"

    /// Model source types this provider can honor on Apple platforms. Hosts download `remote` files
    /// themselves and hand them over as one of these; `registry` is not supported.
    public static let supportedModelSourceTypes: [SourceType] = [.bundled, .programmatic, .appManaged, .filesystem]

    /// Largest WAV artifact this provider writes. Duplicates the engine's default per-artifact limit
    /// on purpose, as the system speech providers do, so synthesis stops at the cap instead of
    /// producing audio the store would refuse.
    public static let maxArtifactBytes = 16 * 1024 * 1024

    fileprivate static let task = TaskKind.textToSpeech.rawValue
    private static let mediaType = "audio/wav"
    private static let platform = "apple"

    public let id: String
    private let modelPackage: ModelPackage
    private let runtime: any NeuralSpeechRuntime
    private let timeout: Duration?
    private let turns = NeuralSpeechTurns()
    private let load = NeuralSpeechModelLoad()

    public init(options: NeuralSpeechProviderOptions) {
        self.id = options.id ?? "\(Self.defaultId):\(options.modelPackage.id)"
        self.modelPackage = options.modelPackage
        self.runtime = options.runtime
        self.timeout = options.timeout
    }

    // MARK: - Descriptor and capabilities

    public func describe() -> ProviderDescriptor {
        var locales: [String] = []
        for voice in modelPackage.speech?.voices ?? [] {
            for tag in voice.locales where !locales.contains(tag) {
                locales.append(tag)
            }
        }
        return ProviderDescriptor(
            id: id,
            type: .local,
            model: modelPackage.id,
            transport: .inProcess,
            supports: ProviderSupports(
                run: true,
                // Lifecycle only: the stream carries no audio, it is what `speak()` can cancel.
                streaming: true,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .hard,
            tasks: [Self.task],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: Self.task,
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(prepare: true, run: true, stream: true),
                    cancel: .hard,
                    outputs: [
                        ProviderTaskOutput(delivery: .playback),
                        ProviderTaskOutput(delivery: .artifact, mediaTypes: [Self.mediaType])
                    ],
                    locales: locales.isEmpty ? nil : locales,
                    privacy: ProviderPrivacy(dataLeavesDevice: false)
                )
            ],
            privacy: ProviderPrivacy(dataLeavesDevice: false)
        )
    }

    /// Never loads the model: a cold provider reports `readiness: .cold` until it is loaded.
    public func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        let pkg = modelPackage
        let issues = getModelPackageValidationIssues(pkg)
        if !issues.isEmpty {
            let summary = issues.map { "\($0.path) \($0.message)" }.joined(separator: "; ")
            return Self.unavailable("model package malformed: \(summary)")
        }

        let tasks = pkg.tasks ?? []
        guard tasks.contains(Self.task), let speech = pkg.speech else {
            let declared = tasks.isEmpty ? "no tasks" : tasks.joined(separator: ", ")
            return Self.unavailable(
                "unsupported task: the model package declares \(declared) and no speech pipeline for '\(Self.task)'."
            )
        }

        if let channels = speech.channels, channels != 1 {
            return Self.unavailable("unsupported channels: \(channels)")
        }

        if let sourceType = pkg.source?.sourceType, !Self.supportedModelSourceTypes.contains(sourceType) {
            let supported = Self.supportedModelSourceTypes.map(\.rawValue).joined(separator: ", ")
            return Self.unavailable(
                "model source unavailable: '\(sourceType.rawValue)' model sources are unsupported on Apple platforms; "
                    + "supply model files as \(supported)."
            )
        }

        if let platforms = pkg.runtime?.platforms, !platforms.isEmpty, !platforms.contains(Self.platform) {
            return Self.unavailable(
                "platform unsupported: the model package targets \(platforms.joined(separator: ", ")) and does not list '\(Self.platform)'."
            )
        }

        let availability = await runtime.availability(pkg)
        guard availability.available else {
            return Self.unavailable(availability.reason ?? "The neural speech runtime cannot run this package.")
        }
        let state = await load.state
        if let failure = state.failure {
            return Self.unavailable(failure)
        }

        // Until the provider has loaded the model, the runtime's hint (when it gives one) wins over `.cold`.
        let hint = state.loaded ? nil : availability.readiness.flatMap { ProviderReadiness(rawValue: $0.rawValue) }
        return ProviderDynamicCapabilities(
            available: true,
            taskCapabilities: [
                ProviderTaskAvailability(
                    kind: Self.task,
                    voices: speech.voices.map { voice in
                        ProviderVoice(
                            locale: voice.locales.first ?? "",
                            gender: voice.gender,
                            networkRequired: false,
                            id: voice.id,
                            name: voice.name,
                            readiness: hint,
                            locales: voice.locales
                        )
                    },
                    readiness: state.loaded ? nil : (hint ?? .cold)
                )
            ]
        )
    }

    /// Loads the model ahead of the first run. Nothing is downloaded: the host supplies the files.
    public func prepare(context: ProviderPrepareContext) -> AsyncThrowingStream<PreparationProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.ensureLoaded(runId: context.runId)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Runs

    /// Plays or writes the speech in Mode 1. Task cancellation stops the audio.
    public func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        let attempt = Attempt(
            runId: context.runId,
            hostServices: context.hostServices,
            voice: context.voice,
            artifacts: context.artifacts,
            commit: { context.commit() }
        )
        let output = try await execute(request, attempt)
        return TaskResult(
            runId: context.runId,
            output: output,
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    /// Plays or writes the speech in Mode 2. The stream carries no audio: it is only the run's
    /// lifecycle, and it ends with a `result` event, or quietly when cancelled, because the engine
    /// emits the cancelled terminal.
    public func stream(
        request: TaskRequest,
        context: ProviderStreamContext
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let attempt = Attempt(
                        runId: context.runId,
                        hostServices: context.hostServices,
                        voice: context.voice,
                        artifacts: context.artifacts,
                        commit: { context.commit() }
                    )
                    let output = try await self.execute(request, attempt)
                    continuation.yield(.result(output: output, finishReason: .stop))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if context.cancellation.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            context.cancellation.onCancel { task.cancel() }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ request: TaskRequest, _ attempt: Attempt) async throws -> TaskOutput {
        let runId = attempt.runId
        // The origin of every timing: before validation, the turn wait, voice check and commit.
        let receivedAt = Date()
        guard let speech = request.speech, let mode = request.delivery?.mode, mode == .playback || mode == .artifact else {
            throw createCapabilityMismatch(
                message: "Neural speech can only play or write text-to-speech requests.",
                runId: runId,
                providerId: id
            )
        }
        let synthesis = Synthesis(runId: runId, timeoutMs: budgetMs(request), budgetEndsAtFirstChunk: mode == .playback)

        do {
            if mode == .artifact {
                return try await writeArtifact(speech, attempt: attempt, synthesis: synthesis)
            }
            try await turns.acquire()
            do {
                // A waiter cancelled just as it is handed the turn opens no session.
                try Task.checkCancellation()
                let output = try await play(speech, attempt: attempt, receivedAt: receivedAt, synthesis: synthesis)
                await turns.release()
                return output
            } catch {
                await turns.release()
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IndeRunException {
            throw toIndeRunException(error, fallbackRunId: runId, fallbackProviderId: id)
        } catch {
            throw createInternal(
                message: "Neural speech failed.",
                runId: runId,
                providerId: id,
                details: ["originalError": JSONAny(String(describing: error))]
            )
        }
    }

    /// Playback, in this utterance's turn. Refuses before commit when the host has no audio output
    /// or the bound voice is not the package's; stops the session on every exit once it is open.
    private func play(
        _ speech: SpeechInput,
        attempt: Attempt,
        receivedAt: Date,
        synthesis: Synthesis
    ) async throws -> TaskOutput {
        guard let audioOutput = attempt.hostServices.audioOutput else {
            throw createCapabilityMismatch(
                message: "The host offers no audio output to play speech.",
                runId: synthesis.runId,
                providerId: id,
                details: ["code": JSONAny("audio_output_unavailable")]
            )
        }
        let resolved = try resolveVoice(speech, bound: attempt.voice, runId: synthesis.runId)
        try await ensureLoaded(runId: synthesis.runId)
        let chunks = SentenceChunks(
            provider: self,
            sentences: try sentences(of: speech.text, runId: synthesis.runId),
            voice: resolved,
            synthesis: synthesis
        )
        defer { chunks.close() }
        let sampleRate = resolved.sampleRate

        // The session measures firstAudioMs() from the start of its own open(), so the shift to the
        // request-received origin counts from the instant before the call, not from its return.
        let openStartedAt = Date()
        let session: any AudioOutputSession
        do {
            session = try await audioOutput.open(format: AudioOutputFormat(sampleRate: sampleRate))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        defer { session.stop() }

        do {
            // A cancel stops the output at once, also while a write waits on backpressure or
            // drain() waits for the buffered audio to play.
            return try await withTaskCancellationHandler {
                let played = try await playSentences(chunks, to: session, commit: attempt.commit, runId: synthesis.runId)
                try await session.drain()
                try Task.checkCancellation()
                // The session counts from the start of open(); shift it to the request-received origin.
                let firstAudioMs = session.firstAudioMs().map { openStartedAt.timeIntervalSince(receivedAt) * 1000 + $0 }
                let timing = PlaybackTiming(
                    durationMs: Double(played.frames) / Double(sampleRate) * 1000,
                    firstAudioMs: firstAudioMs,
                    firstChunkMs: played.firstChunkAt.timeIntervalSince(receivedAt) * 1000
                )
                return TaskOutput(playback: PlaybackOutput(timing: timing), speech: resolved.output)
            } onCancel: {
                session.stop()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Writes every sentence's chunks to `session`, committing immediately before the first write.
    /// - Returns: When the first chunk arrived and how many frames were written.
    /// - Throws: `CancellationError` when cancelled or when the run can no longer commit; the caller
    ///   stops the session either way.
    private func playSentences(
        _ chunks: SentenceChunks,
        to session: any AudioOutputSession,
        commit: @Sendable () -> Bool,
        runId: String
    ) async throws -> (firstChunkAt: Date, frames: Int) {
        var firstChunkAt: Date?
        var frames = 0
        while let chunk = try await chunks.next() {
            if firstChunkAt == nil {
                firstChunkAt = Date()
                guard !Task.isCancelled, commit() else { throw CancellationError() }
            }
            frames += chunk.samples.count
            try await session.write(chunk.samples)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard let firstChunkAt else { throw noAudio(runId) }
        return (firstChunkAt, frames)
    }

    /// Artifact delivery: buffers the PCM up to ``maxArtifactBytes``, then writes the WAV once.
    /// Leaving the loop at the cap closes the runtime's iteration, so synthesis stops there. The
    /// chunks' one absolute deadline is checked again before the artifact is created and
    /// immediately before `finish()`.
    private func writeArtifact(_ speech: SpeechInput, attempt: Attempt, synthesis: Synthesis) async throws -> TaskOutput {
        let resolved = try resolveVoice(speech, bound: attempt.voice, runId: synthesis.runId)
        try await ensureLoaded(runId: synthesis.runId)
        let chunks = SentenceChunks(
            provider: self,
            sentences: try sentences(of: speech.text, runId: synthesis.runId),
            voice: resolved,
            synthesis: synthesis
        )
        defer { chunks.close() }
        let sampleRate = resolved.sampleRate

        var samples: [Int16] = []
        while let chunk = try await chunks.next() {
            if SpeechWAV.headerBytes + 2 * (samples.count + chunk.samples.count) > Self.maxArtifactBytes {
                throw createUnavailable(
                    message: "The synthesized audio exceeds the artifact size limit.",
                    runId: synthesis.runId,
                    providerId: id,
                    details: ["code": JSONAny("artifact_too_large")]
                )
            }
            samples.append(contentsOf: chunk.samples)
        }
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw noAudio(synthesis.runId) }

        let pcm = samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
        if chunks.pastDeadline { throw timedOut(synthesis.runId) }
        let writer = attempt.artifacts.create(
            spec: ArtifactSpec(mediaType: Self.mediaType, durationMs: Double(samples.count) / Double(sampleRate) * 1000)
        )
        do {
            try writer.write(SpeechWAV.encode(samples: pcm, sampleRate: sampleRate))
            if chunks.pastDeadline { throw timedOut(synthesis.runId) }
            return TaskOutput(artifact: try writer.finish(), speech: resolved.output)
        } catch {
            writer.abort()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: - Voice, text and model

    /// Picks the package voice that speaks. A voice the plan bound must be one of the package's,
    /// else the run is refused before commit so it can still fall back. Unbound, the request's voice
    /// id is honoured when the package has it, then the first voice for the request's language,
    /// then the first voice.
    private func resolveVoice(
        _ speech: SpeechInput,
        bound: ProviderVoice?,
        runId: String
    ) throws -> ResolvedVoice {
        guard let speechPackage = modelPackage.speech else {
            throw createCapabilityMismatch(message: "The model package has no speech pipeline.", runId: runId, providerId: id)
        }
        let voices = speechPackage.voices
        let voice: SpeechModelVoice?
        if let boundId = bound?.id {
            voice = voices.first { $0.id == boundId }
        } else {
            let requested = speech.voice?.id
            voice = voices.first { requested != nil && $0.id == requested }
                ?? voices.first { candidate in candidate.locales.contains { Self.sameLanguage($0, speech.locale) } }
                ?? voices.first
        }
        guard let voice else {
            throw createCapabilityMismatch(
                message: "The model package has no voice '\(bound?.id ?? "")'.",
                runId: runId,
                providerId: id,
                details: ["code": JSONAny("voice_not_available")]
            )
        }
        return ResolvedVoice(voice: voice, locale: Self.locale(for: voice, requested: speech.locale), sampleRate: speechPackage.sampleRate)
    }

    private func sentences(of text: String, runId: String) throws -> [String] {
        let sentences = SpeechTextFrontend.splitSentences(text)
        guard !sentences.isEmpty else {
            throw createCapabilityMismatch(message: "The text has nothing to say.", runId: runId, providerId: id)
        }
        return sentences
    }

    /// Loads the model once; concurrent callers share one load. A failed load is remembered, so
    /// routing stops choosing this provider instead of every call retrying it; it refuses before any
    /// output, so the run can fall back.
    private func ensureLoaded(runId: String) async throws {
        let runtime = runtime
        let modelPackage = modelPackage
        if let failure = await load.ensure({ await runtime.prepare(modelPackage) }) {
            throw createCapabilityMismatch(message: failure, runId: runId, providerId: id)
        }
    }

    /// A request's `constraints.timeoutMs`, else the option; zero or less is unbounded.
    private func budgetMs(_ request: TaskRequest) -> Double? {
        let option = timeout.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
        guard let timeoutMs = request.constraints?.timeoutMs.map(Double.init) ?? option, timeoutMs > 0 else { return nil }
        return timeoutMs
    }

    // MARK: - Errors

    private func noAudio(_ runId: String) -> IndeRunException {
        createInternal(message: "The neural speech runtime produced no audio.", runId: runId, providerId: id)
    }

    fileprivate func timedOut(_ runId: String) -> IndeRunException {
        createTimeout(message: "Neural speech synthesis timed out.", runId: runId, providerId: id)
    }

    fileprivate func wrongSampleRate(_ chunk: PcmChunk, runId: String) -> IndeRunException {
        createInternal(
            message: "The runtime produced \(chunk.sampleRate) Hz audio for a \(modelPackage.speech?.sampleRate ?? 0) Hz package; "
                + "the provider never resamples.",
            runId: runId,
            providerId: id
        )
    }

    fileprivate func mapRuntimeError(_ error: Error, runId: String) -> IndeRunException {
        if let runtimeError = error as? NeuralSpeechRuntimeError {
            let details = runtimeError.originalErrorDescription.map { ["originalError": JSONAny($0)] }
            switch runtimeError.kind {
            case .capability:
                return createCapabilityMismatch(message: runtimeError.message, runId: runId, providerId: id, details: details)
            case .unavailable:
                return createUnavailable(message: runtimeError.message, runId: runId, providerId: id, details: details)
            case .timeout:
                return createTimeout(message: runtimeError.message, runId: runId, providerId: id, details: details)
            case .internalFailure:
                return createInternal(message: runtimeError.message, runId: runId, providerId: id, details: details)
            }
        }
        if let error = error as? IndeRunException {
            return toIndeRunException(error, fallbackRunId: runId, fallbackProviderId: id)
        }
        return createInternal(
            message: "Neural speech synthesis failed.",
            runId: runId,
            providerId: id,
            details: ["originalError": JSONAny(String(describing: error))]
        )
    }

    fileprivate func synthesize(_ text: String, voiceId: String, locale: String) -> AsyncThrowingStream<PcmChunk, Error> {
        runtime.synthesize(NeuralSpeechSynthesisInput(modelPackage: modelPackage, text: text, locale: locale, voiceId: voiceId))
    }

    // MARK: - Helpers

    private static func unavailable(_ reason: String) -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(available: false, reason: reason)
    }

    private static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        language(of: lhs) == language(of: rhs)
    }

    private static func language(of tag: String) -> String {
        tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag.lowercased()
    }

    /// The voice's tag for the requested locale: exact first, then by language, else the request's.
    private static func locale(for voice: SpeechModelVoice, requested: String) -> String {
        voice.locales.first { $0.caseInsensitiveCompare(requested) == .orderedSame }
            ?? voice.locales.first { sameLanguage($0, requested) }
            ?? requested
    }
}

/// What one attempt was handed, from a `RunContext` or a `ProviderStreamContext`.
private struct Attempt {
    let runId: String
    let hostServices: HostServices
    /// The voice the plan bound, if any.
    let voice: ProviderVoice?
    let artifacts: any ArtifactSink
    let commit: @Sendable () -> Bool
}

/// The package voice that speaks, the tag it speaks for the request, and the package's rate.
private struct ResolvedVoice {
    let voice: SpeechModelVoice
    let locale: String
    let sampleRate: Int

    /// The locale and voice actually used, as the run's output reports them.
    var output: SpeechOutput {
        SpeechOutput(locale: locale, voice: SpeechOutputVoice(gender: nil, id: voice.id, name: voice.name))
    }
}

/// What every sentence of one run shares.
private struct Synthesis {
    let runId: String
    /// The budget, from the start of synthesis. `nil` is unbounded.
    let timeoutMs: Double?
    /// True for playback, which commits on the first chunk; false for an artifact.
    let budgetEndsAtFirstChunk: Bool
}

// MARK: - Chunk source

private struct SynthesisTimedOut: Error {}

/// Pulls one element at a time, from whichever task asks; never from two at once.
private final class PcmIterator: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<PcmChunk, Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<PcmChunk, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> PcmChunk? {
        var current = iterator
        defer { iterator = current }
        return try await current.next()
    }
}

/// The chunks of every sentence in order, pulled by the task that plays or buffers them; the
/// playback and artifact paths share it. Each sentence gets its own runtime iteration. The budget
/// starts with the first pull and races every pull until it ends: at the first chunk when
/// `budgetEndsAtFirstChunk`, else with the synthesis. A cancel of the pulling task ends the chunks
/// (`nil`); an expired budget throws `Timeout`; a chunk at another sample rate throws `Internal`; a
/// runtime failure is mapped onto the IndeRun taxonomy. ``close()`` drops the runtime's iteration,
/// which ends its synthesis; it keeps the deadline, which ``pastDeadline`` reads for the work that
/// follows the synthesis.
private final class SentenceChunks {
    private let provider: NeuralSpeechProvider
    private let sentences: [String]
    private let voice: ResolvedVoice
    private let synthesis: Synthesis
    private var index = 0
    private var current: PcmIterator?
    private var started = false
    private var deadline: Date?

    init(provider: NeuralSpeechProvider, sentences: [String], voice: ResolvedVoice, synthesis: Synthesis) {
        self.provider = provider
        self.sentences = sentences
        self.voice = voice
        self.synthesis = synthesis
    }

    func next() async throws -> PcmChunk? {
        if !started {
            started = true
            deadline = synthesis.timeoutMs.map { Date().addingTimeInterval($0 / 1000) }
        }
        while true {
            if Task.isCancelled {
                close()
                return nil
            }
            if current == nil {
                guard index < sentences.count else { return nil }
                current = PcmIterator(provider.synthesize(sentences[index], voiceId: voice.voice.id, locale: voice.locale))
                index += 1
            }
            let chunk: PcmChunk?
            do {
                chunk = try await pull()
            } catch is SynthesisTimedOut {
                close()
                throw provider.timedOut(synthesis.runId)
            } catch {
                close()
                if Task.isCancelled { return nil }
                throw provider.mapRuntimeError(error, runId: synthesis.runId)
            }
            guard let chunk else {
                current = nil
                continue
            }
            if Task.isCancelled {
                close()
                return nil
            }
            guard chunk.sampleRate == voice.sampleRate else {
                close()
                throw provider.wrongSampleRate(chunk, runId: synthesis.runId)
            }
            if synthesis.budgetEndsAtFirstChunk {
                deadline = nil
            }
            return chunk
        }
    }

    func close() {
        current = nil
        index = sentences.count
    }

    /// Whether the budget's one absolute deadline has passed; `false` when there is none or it ended.
    var pastDeadline: Bool {
        deadline.map { $0 <= Date() } ?? false
    }

    /// The current sentence's next chunk, raced against what is left of the budget.
    private func pull() async throws -> PcmChunk? {
        guard let current else { return nil }
        guard let deadline else { return try await current.next() }
        let remaining = deadline.timeIntervalSinceNow * 1000
        guard remaining > 0 else { throw SynthesisTimedOut() }
        return try await withThrowingTaskGroup(of: PcmChunk?.self) { group in
            group.addTask { try await current.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000))
                throw SynthesisTimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}

// MARK: - Turns and loading

/// Waiters for the one audible utterance a provider plays at a time, first in first out.
/// Cancelling a waiter removes it from the queue, so it never plays. A copy of the one in
/// `AppleSystemSpeechProvider`.
private actor NeuralSpeechTurns {
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.remove(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func remove(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Whether the model loaded, or why it did not. Concurrent callers share one load.
private actor NeuralSpeechModelLoad {
    private var loaded = false
    private var failure: String?
    private var pending: Task<Void, Never>?

    var state: (loaded: Bool, failure: String?) { (loaded, failure) }

    /// Loads once, remembering a failure. - Returns: `nil` when loaded, else the failure.
    func ensure(_ prepare: @escaping @Sendable () async -> NeuralSpeechAvailability) async -> String? {
        if !loaded, failure == nil {
            let loading = pending ?? Task {
                let result = await prepare()
                self.finish(result)
            }
            pending = loading
            await loading.value
        }
        return loaded ? nil : (failure ?? "The speech model failed to load.")
    }

    private func finish(_ result: NeuralSpeechAvailability) {
        pending = nil
        if result.available {
            loaded = true
        } else {
            failure = result.reason ?? "The speech model failed to load."
        }
    }
}
