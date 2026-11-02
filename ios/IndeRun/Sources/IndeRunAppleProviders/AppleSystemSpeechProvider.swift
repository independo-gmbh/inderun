import Foundation
import IndeRunContracts
import IndeRunCore

/// Waiters for the one audible utterance a provider plays at a time, first in first out.
/// Cancelling a waiter removes it from the queue, so it never plays.
private actor SpeechTurns {
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

/// The identifiers of voices known to be loaded.
private final class LoadedVoices: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String> = []

    var identifiers: Set<String> { lock.withLock { loaded } }

    func insert(_ identifier: String) {
        _ = lock.withLock { loaded.insert(identifier) }
    }
}

/// System text-to-speech through `AVSpeechSynthesizer`: managed playback and retrievable
/// `audio/wav`, in both modes.
///
/// Registered explicitly, never by `AppleProviderRegistryFactory`: the router probes every
/// registered provider on every request, and an application that does not speak should not
/// pay for a voice listing (ADR 018).
///
/// Playback commits immediately before the synthesizer starts, so a failure after that ends the
/// run rather than speaking the text twice through another provider. `speak()` uses `stream`,
/// whose cancellation token stops the audio; `run` stops it on Swift task cancellation. Provider
/// utterances play one at a time, first in first out, and an utterance commits only when its
/// turn comes. Applications that want to interrupt cancel first.
///
/// `AVSpeechSynthesisVoice` has no network flag, so the declaration that data stays on the device
/// is an assumption from the listed voices being the installed ones, not something the API proves.
/// `docs/verification/system-speech.md` tracks the check of it. The audio session belongs to the
/// application.
public final class AppleSystemSpeechProvider: StreamingProviderAdapter, PreparableProviderAdapter, Sendable {
    /// Stable provider id used in routing explanations and telemetry.
    public static let defaultId = "apple_system_speech"

    private static let task = TaskKind.textToSpeech.rawValue
    private static let mediaType = "audio/wav"
    /// The engine's default per-artifact limit: past it the writer would refuse the bytes anyway,
    /// so the render stops early instead of buffering them.
    private static let maxRenderedBytes = 16 * 1024 * 1024

    private let id: String
    private let runtime: any AppleSpeechRuntime
    private let turns = SpeechTurns()
    /// Voices spoken or warmed since launch. The system may still evict one, so a reported `ready`
    /// is a strong hint, not a guarantee.
    private let loaded = LoadedVoices()

    /// Creates a provider backed by the system speech synthesizer.
    ///
    /// - Parameter id: Provider identifier used in route explanations and telemetry.
    public convenience init(id: String = AppleSystemSpeechProvider.defaultId) {
        self.init(id: id, runtime: SystemAppleSpeechRuntime())
    }

    init(id: String = AppleSystemSpeechProvider.defaultId, runtime: any AppleSpeechRuntime) {
        self.id = id
        self.runtime = runtime
    }

    /// Returns static provider metadata used by the router before dynamic checks.
    public func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .systemService,
            supports: ProviderSupports(
                run: true,
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
                    ]
                )
            ],
            privacy: ProviderPrivacy(dataLeavesDevice: false)
        )
    }

    /// Reports the installed voices. No voices means the task cannot run on this host.
    public func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        let voices = runtime.voices()
        guard !voices.isEmpty else {
            return ProviderDynamicCapabilities(available: false, reason: "No speech voice is installed.")
        }
        let warm = loaded.identifiers
        let listed = voices.map { voice in
            ProviderVoice(
                locale: voice.locale,
                gender: voice.gender,
                id: voice.identifier,
                name: voice.name,
                readiness: warm.contains(voice.identifier) ? nil : .cold
            )
        }
        return ProviderDynamicCapabilities(
            available: true,
            taskCapabilities: [
                ProviderTaskAvailability(kind: Self.task, voices: listed, readiness: warm.isEmpty ? .cold : nil)
            ]
        )
    }

    /// Loads a voice with a silent render, in the speech turn so it cannot collide with playback.
    /// iOS offers no voice download, so this is all there is to prepare.
    public func prepare(context: ProviderPrepareContext) -> AsyncThrowingStream<PreparationProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let voice = context.voice?.id.flatMap(runtime.voice(identifier:))
                        ?? runtime.defaultVoice(locale: context.locale)
                    if let voice {
                        try await turns.acquire()
                        do {
                            try await runtime.warm(voice: voice)
                            await turns.release()
                        } catch {
                            await turns.release()
                            throw error
                        }
                        loaded.insert(voice.identifier)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Speaks or synthesizes in Mode 1. Task cancellation stops the audio.
    public func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        let output = try await execute(
            request,
            runId: context.runId,
            bound: context.voice,
            artifacts: context.artifacts,
            commit: context.commit
        )
        return TaskResult(
            runId: context.runId,
            output: output,
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    /// Speaks or synthesizes in Mode 2. The stream carries no audio: it is only the run's
    /// lifecycle, and it ends with a `result` event, or quietly when cancelled, because the engine
    /// emits the cancelled terminal.
    public func stream(
        request: TaskRequest,
        context: ProviderStreamContext
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = try await self.execute(
                        request,
                        runId: context.runId,
                        bound: context.voice,
                        artifacts: context.artifacts,
                        commit: context.commit
                    )
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

    private func execute(
        _ request: TaskRequest,
        runId: String,
        bound: ProviderVoice?,
        artifacts: any ArtifactSink,
        commit: @escaping @Sendable () -> Bool
    ) async throws -> TaskOutput {
        guard let speech = request.speech, let delivery = request.delivery else {
            throw createCapabilityMismatch(
                message: "Apple system speech serves text-to-speech requests only.",
                runId: runId,
                providerId: id
            )
        }

        do {
            switch delivery.mode {
            case .playback:
                return try await play(speech, bound: bound, runId: runId, commit: commit)
            case .artifact:
                let voice = try resolveVoice(speech: speech, bound: bound, runId: runId)
                return try await synthesize(speech.text, voice: voice, artifacts: artifacts)
            case .inline:
                throw createCapabilityMismatch(
                    message: "Apple system speech cannot deliver speech inline.",
                    runId: runId,
                    providerId: id
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IndeRunException {
            throw toIndeRunException(error, fallbackRunId: runId, fallbackProviderId: id)
        } catch {
            throw createInternal(
                message: "Apple system speech failed.",
                runId: runId,
                providerId: id,
                details: ["originalError": JSONAny(error.localizedDescription)]
            )
        }
    }

    private func play(
        _ speech: SpeechInput,
        bound: ProviderVoice?,
        runId: String,
        commit: @Sendable () -> Bool
    ) async throws -> TaskOutput {
        try await turns.acquire()
        do {
            let voice = try resolveVoice(speech: speech, bound: bound, runId: runId)
            // Committed only now: a call that waited its turn has made no sound, and may have
            // been cancelled meanwhile.
            guard commit() else { throw CancellationError() }
            let durationMs = try await runtime.speak(text: speech.text, voice: voice)
            loaded.insert(voice.identifier)
            await turns.release()
            return TaskOutput(playback: PlaybackOutput(durationMs: durationMs), speech: Self.used(voice))
        } catch {
            await turns.release()
            throw error
        }
    }

    private func synthesize(
        _ text: String,
        voice: AppleSpeechVoice,
        artifacts: any ArtifactSink
    ) async throws -> TaskOutput {
        let rendered = try await runtime.render(text: text, voice: voice, maxBytes: Self.maxRenderedBytes)
        let writer = artifacts.create(spec: ArtifactSpec(mediaType: Self.mediaType, durationMs: rendered.durationMs))
        do {
            try writer.write(SpeechWAV.encode(rendered))
            return TaskOutput(artifact: try writer.finish(), speech: Self.used(voice))
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Re-finds the voice the plan bound, at the turn that will use it. A voice removed since
    /// planning is refused before commit, so the run can still fall back.
    private func resolveVoice(speech: SpeechInput, bound: ProviderVoice?, runId: String) throws -> AppleSpeechVoice {
        let match = bound.flatMap { $0.id.flatMap(runtime.voice(identifier:)) } ?? unbound(speech, bound: bound)
        guard let match else {
            throw createCapabilityMismatch(
                message: "No installed voice can speak locale '\(speech.locale)'.",
                runId: runId,
                providerId: id,
                details: ["code": JSONAny("voice_not_available")]
            )
        }
        return match
    }

    /// The first voice for the locale when the plan bound none. A bound voice that is gone stays
    /// gone: nothing replaces it here.
    private func unbound(_ speech: SpeechInput, bound: ProviderVoice?) -> AppleSpeechVoice? {
        guard bound == nil else { return nil }
        return runtime.voices().first { voice in
            speech.localeMatch == .exact
                ? Self.sameTag(voice.locale, speech.locale)
                : Self.language(of: voice.locale) == Self.language(of: speech.locale)
        }
    }

    private static func used(_ voice: AppleSpeechVoice) -> SpeechOutput {
        SpeechOutput(
            locale: voice.locale,
            voice: SpeechOutputVoice(gender: voice.gender, id: voice.identifier, name: voice.name)
        )
    }

    private static func sameTag(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func language(of tag: String) -> String {
        tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? tag
    }
}
