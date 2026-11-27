import Foundation
import IndeRunCore
import IndeRunContracts

// The primary speech API: `speak`, `generateSpeech`, and `listVoices`.
//
// Translation only, like the text API. Each speaking call compiles to exactly one canonical
// `text_to_speech` `TaskRequest`; `listVoices` reads `checkCapabilities`. `speak` is written over
// `stream` because a stream is the only execution a caller can cancel, and stopping audio is the
// point of a playback handle. Mirrors the Web SDK's `facade/speech.ts`; the shared vectors in
// `contracts/fixtures/facade/speech.json` hold the two to the same translation. See ADR 018 and
// `docs/architecture/api-layering.md`.

/// The same policy object as the text API, so a constraint means the same in both.
public typealias SpeechExecutionOptions = TextExecutionOptions

/// What every speech call takes: the text, its locale, the voice, the synthesis controls and the
/// execution policy. `SpeakOptions` adds playback-only settings and `GenerateSpeechOptions` the
/// artifact's, as on the Web and Kotlin SDKs (ADR 025).
public struct SpeechOptions: Sendable {
    /// The text to speak. Plain text; markup such as SSML is out of scope.
    public var text: String
    /// BCP 47 tag, e.g. `"de-AT"`.
    public var locale: String
    /// `.language` (default) requires the language and prefers the region, so `de-AT` may be
    /// served by `de-DE`. `.exact` requires the whole tag.
    public var localeMatch: LocaleMatch?
    /// The voice: ``SpeechVoiceInfo/asSpeechVoice(requirement:)`` for an entry of `listVoices()`,
    /// or provider-neutral traits. A required one never relaxes silently.
    public var voice: SpeechVoice?
    /// Relative speaking rate and pitch (ADR 025). Each is preferred unless marked required; a
    /// required one is met or the call is refused.
    public var controls: SharedSynthesisControls?
    /// Model profile to route within, as configured on the engine. `nil` or `"auto"` routes
    /// across every registered target. Never a vendor model or voice id.
    public var model: String?
    public var execution: SpeechExecutionOptions?
    /// Secure-storage slot for provider credentials. Never a raw secret.
    public var authContextRef: String?
    public var telemetry: TaskRequestTelemetry?
    /// Fixes the run id, for correlation.
    public var requestId: String?

    public init(
        _ text: String,
        locale: String,
        localeMatch: LocaleMatch? = nil,
        voice: SpeechVoice? = nil,
        controls: SharedSynthesisControls? = nil,
        model: String? = nil,
        execution: SpeechExecutionOptions? = nil,
        authContextRef: String? = nil,
        telemetry: TaskRequestTelemetry? = nil,
        requestId: String? = nil
    ) {
        self.text = text
        self.locale = locale
        self.localeMatch = localeMatch
        self.voice = voice
        self.controls = controls
        self.model = model
        self.execution = execution
        self.authContextRef = authContextRef
        self.telemetry = telemetry
        self.requestId = requestId
    }

    fileprivate func taskRequest(delivery: OutputDeliveryRequest) -> TaskRequest {
        TaskRequest(
            requestId: requestId,
            task: TaskDescriptor(kind: .textToSpeech),
            modelProfile: model == ModelProfiles.auto ? nil : model,
            constraints: execution?.taskConstraints,
            preferences: execution?.taskPreferences,
            telemetry: telemetry,
            authContextRef: authContextRef,
            speech: SpeechInput(controls: controls, locale: locale, localeMatch: localeMatch, text: text, voice: voice),
            delivery: delivery
        )
    }
}

/// Options for `speak`: the common ``SpeechOptions`` plus settings that only playback has. The
/// common fields read and write through, so `options.voice = …` works as on ``SpeechOptions``.
@dynamicMemberLookup
public struct SpeakOptions: Sendable {
    public var speech: SpeechOptions
    /// Playback volume of this utterance, 0 to 1 (ADR 025). Never the device volume.
    public var playback: PlaybackControls?

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<SpeechOptions, Value>) -> Value {
        get { speech[keyPath: keyPath] }
        set { speech[keyPath: keyPath] = newValue }
    }

    public init(_ speech: SpeechOptions, playback: PlaybackControls? = nil) {
        self.speech = speech
        self.playback = playback
    }

    /// The common options spelled out, for the usual call that names only a few of them.
    public init(
        _ text: String,
        locale: String,
        localeMatch: LocaleMatch? = nil,
        voice: SpeechVoice? = nil,
        controls: SharedSynthesisControls? = nil,
        playback: PlaybackControls? = nil,
        model: String? = nil,
        execution: SpeechExecutionOptions? = nil,
        authContextRef: String? = nil,
        telemetry: TaskRequestTelemetry? = nil,
        requestId: String? = nil
    ) {
        self.init(
            SpeechOptions(
                text,
                locale: locale,
                localeMatch: localeMatch,
                voice: voice,
                controls: controls,
                model: model,
                execution: execution,
                authContextRef: authContextRef,
                telemetry: telemetry,
                requestId: requestId
            ),
            playback: playback
        )
    }

    /// The canonical `TaskRequest` a `speak` call compiles to.
    public func taskRequest() -> TaskRequest {
        speech.taskRequest(
            delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: nil, mode: .playback, playback: playback)
        )
    }
}

/// Options for `generateSpeech`: the common ``SpeechOptions`` plus the artifact's. There is no
/// playback volume, because nothing is played.
public struct GenerateSpeechOptions: Sendable {
    public var speech: SpeechOptions
    /// Acceptable media types; always a hard requirement. `nil` lets the provider choose.
    public var mediaTypes: [String]?
    /// Opaque application destination, resolved by the host. Never a path or URL.
    public var destinationRef: String?

    public init(_ speech: SpeechOptions, mediaTypes: [String]? = nil, destinationRef: String? = nil) {
        self.speech = speech
        self.mediaTypes = mediaTypes
        self.destinationRef = destinationRef
    }

    /// The canonical `TaskRequest` a `generateSpeech` call compiles to.
    public func taskRequest() -> TaskRequest {
        speech.taskRequest(
            delivery: OutputDeliveryRequest(
                destinationRef: destinationRef,
                mediaTypes: mediaTypes,
                mode: .artifact,
                playback: nil
            )
        )
    }
}

/// How a `speak` run ended, when it did not fail.
public struct SpokenSpeech: Sendable {
    /// `.cancelled` when playback was stopped; otherwise as the provider reported it.
    public let finishReason: FinishReason?
    /// How long the audio played and how soon it began, where the provider reports it. Absent when
    /// the provider knows nothing. See `PlaybackTiming`.
    public let timing: PlaybackTiming?
    /// The locale and voice actually used, so an unmet preference is visible.
    public let speech: SpeechOutput?
    public let runId: String
    public let provenance: ExecutionProvenance?
}

/// What `speak` returns: a handle on playback in progress.
public final class SpeechPlayback: Sendable {
    public let runId: String
    private let ending: Task<SpokenSpeech, Error>
    private let cancellation: @Sendable (String?) -> Void

    init(run: StreamRun) {
        let runId = run.handle.runId
        self.runId = runId
        cancellation = { reason in run.cancel(reason: reason) }
        ending = Task {
            // As in `streamText`: the terminal event settles the run, and a source that stays
            // open after it must not hold the result back.
            for try await event in run.events where event.type == "terminal" {
                return try settleSpeech(event, runId: runId)
            }
            throw createInternal(message: "Run \(runId) ended without a terminal event.", runId: runId)
        }
    }

    /// Waits for the run's ending: returns when playback finishes or is stopped, throws the
    /// run's `IndeRunException` on failure. Can be awaited any number of times.
    public func result() async throws -> SpokenSpeech {
        try await ending.value
    }

    /// Stops playback; idempotent.
    public func cancel(reason: String? = nil) {
        cancellation(reason)
    }
}

/// What `generateSpeech` returns.
public struct GeneratedSpeech: Sendable {
    /// A reference to the audio. Read it with `readArtifact`, release it with `disposeArtifact`.
    public let artifact: MediaArtifact
    /// The locale and voice actually used, so an unmet preference is visible.
    public let speech: SpeechOutput?
    public let finishReason: FinishReason
    public let runId: String
    public let provenance: ExecutionProvenance?
    /// The canonical result, for anything the summary above leaves out.
    public let taskResult: TaskResult
}

/// Whether the provider names the model that speaks a voice.
public enum SpeechVoiceKind: String, Codable, Sendable {
    /// The provider names no model: a system voice, or any provider without a model id.
    case platform
    /// The provider names the model that speaks, so the voice belongs to that model.
    case model
}

/// One speech control as a voice offers it on one delivery: the merged state of the task's and the
/// voice's `controlStates`, reported as declared and never decided. A field the provider has not
/// reported stays `nil`, and `nil` is not support.
public struct SpeechVoiceControl: Sendable, Equatable, Codable {
    public let id: SpeechControlId
    public let delivery: ControlDelivery
    public let phase: SpeechControlPhase
    /// Whether the control works here. `nil` when unknown.
    public let available: Bool?
    /// Why the control does not work, when `available` is `false`.
    public let reason: String?
    /// The values it accepts. `nil` when unknown, or when the control is unavailable.
    public let range: SpeechControlRange?

    public static func == (lhs: SpeechVoiceControl, rhs: SpeechVoiceControl) -> Bool {
        lhs.id == rhs.id && lhs.delivery == rhs.delivery && lhs.phase == rhs.phase
            && lhs.available == rhs.available && lhs.reason == rhs.reason
            && lhs.range?.min == rhs.range?.min && lhs.range?.max == rhs.range?.max
            && lhs.range?.step == rhs.range?.step
            && lhs.range?.speechControlRangeDefault == rhs.range?.speechControlRangeDefault
            && (lhs.range == nil) == (rhs.range == nil)
    }
}

/// A voice a registered provider offers right now. Pass ``asSpeechVoice(requirement:)`` as
/// `voice` to speak with it. `id` is opaque and meaningful only on `providerId` on this device:
/// read it, store it, but never write one by hand.
public struct SpeechVoiceInfo: Sendable, Equatable, Codable {
    public let providerId: String
    /// ``SpeechVoiceKind/model`` when the provider names the model that speaks.
    public let kind: SpeechVoiceKind
    /// The model that speaks this voice. Present exactly when `kind` is ``SpeechVoiceKind/model``.
    public let model: String?
    /// `nil` when the provider cannot address single voices.
    public let id: String?
    /// Label for showing the voice to a person. Not unique, so never compare it.
    public let name: String?
    /// The voice's primary BCP 47 tag.
    public let locale: String
    /// Every BCP 47 tag the voice speaks. `nil` when it speaks only `locale`.
    public let locales: [String]?
    public let gender: VoiceGender?
    /// `true` when the voice sends text off the device. `nil` inherits the provider's posture.
    public let networkRequired: Bool?
    /// `.notPrepared` and `.preparing` mean "not yet". `nil` means ready. See `prepare()`.
    public let readiness: ProviderReadiness?
    /// The per-request controls of this voice, one per declared control and delivery. Present only
    /// when `listVoices` is called with `includeControls`.
    public let controls: [SpeechVoiceControl]?
    /// `false` for a voice of an unavailable provider or task. Present only when `listVoices` is
    /// called with `includeUnavailable`.
    public let available: Bool?

    init(
        providerId: String,
        kind: SpeechVoiceKind,
        model: String?,
        id: String?,
        name: String?,
        locale: String,
        locales: [String]?,
        gender: VoiceGender?,
        networkRequired: Bool?,
        readiness: ProviderReadiness?,
        controls: [SpeechVoiceControl]? = nil,
        available: Bool? = nil
    ) {
        self.providerId = providerId
        self.kind = kind
        self.model = model
        self.id = id
        self.name = name
        self.locale = locale
        self.locales = locales
        self.gender = gender
        self.networkRequired = networkRequired
        self.readiness = readiness
        self.controls = controls
        self.available = available
    }

    /// This voice as a request's `voice`. Left preferred, it falls back to its traits when it is
    /// gone or another provider serves the run; a required one never relaxes silently.
    public func asSpeechVoice(requirement: RequirementLevel? = nil) -> SpeechVoice {
        SpeechVoice(gender: gender, id: id, providerId: id == nil ? nil : providerId, requirement: requirement)
    }
}

private func settleSpeech(_ terminal: StreamEvent, runId: String) throws -> SpokenSpeech {
    let payload = terminal.payload
    let timing = payload?.output?.playback?.timing
    let speech = payload?.output?.speech
    switch payload?.outcome {
    case .some(.completed):
        return SpokenSpeech(
            finishReason: payload?.finishReason,
            timing: timing,
            speech: speech,
            runId: runId,
            provenance: payload?.provenance
        )
    case .some(.cancelled):
        return SpokenSpeech(
            finishReason: .cancelled,
            timing: timing,
            speech: speech,
            runId: runId,
            provenance: payload?.provenance
        )
    case .some(.error):
        throw exceptionFromTerminal(payload, runId: runId)
    case .none:
        throw createInternal(message: "Run \(runId) ended with a malformed terminal event.", runId: runId)
    }
}

/// Case-insensitive BCP 47 comparison, the same one the route planner applies.
private func localeMatches(_ voice: ProviderVoice, _ wanted: String, _ match: LocaleMatch?) -> Bool {
    let want = wanted.lowercased()
    let primary = { (tag: String) in tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) }
    return ([voice.locale] + (voice.locales ?? [])).contains { available in
        let have = available.lowercased()
        return match == .exact ? have == want : primary(have) == primary(want)
    }
}

public extension IndeRunApi {
    /// Speaks through the device: `stream` over a `playback` request. The audible effect is
    /// managed by the provider; the application gets a completion and a way to stop it, never
    /// bytes.
    /// - Throws: Exactly what `stream` throws: validation and routing refusals, before any
    ///   audio could start.
    func speak(_ options: SpeakOptions) async throws -> SpeechPlayback {
        SpeechPlayback(run: try await stream(request: options.taskRequest()))
    }

    /// Synthesizes retrievable audio: `run` over an `artifact` request. Silent, and not
    /// cancellable for the same reason `run` is not. A provider that can only play audio is
    /// refused by routing.
    /// - Throws: Exactly what `run` throws.
    func generateSpeech(_ options: GenerateSpeechOptions) async throws -> GeneratedSpeech {
        let result = try await run(request: options.taskRequest())
        guard let artifact = result.output.artifact else {
            // The engine checks the output against the requested delivery before it returns,
            // so only a foreign `IndeRunApi` can get here.
            throw createInternal(message: "Run \(result.runId) returned no artifact.", runId: result.runId)
        }
        return GeneratedSpeech(
            artifact: artifact,
            speech: result.output.speech,
            finishReason: result.finishReason,
            runId: result.runId,
            provenance: result.provenance,
            taskResult: result
        )
    }

    /// Lists the voices the registered providers offer right now, in registration and provider
    /// order. A provider that is unavailable contributes none (unless `includeUnavailable`); one
    /// that cannot enumerate its voices contributes none either, and can still serve a request. A
    /// projection of `checkCapabilities()` and nothing more: it never prepares, downloads, loads
    /// or synthesizes.
    /// - Parameters:
    ///   - locale: Keep only voices that can serve this BCP 47 tag.
    ///   - localeMatch: How `locale` compares, with the same meaning as on a request.
    ///   - includeControls: Add each voice's per-request controls, read from the same snapshot.
    ///   - includeUnavailable: Also list the voices of unavailable providers and tasks, with what
    ///     is known of them and `available: false`.
    func listVoices(
        locale: String? = nil,
        localeMatch: LocaleMatch? = nil,
        includeControls: Bool = false,
        includeUnavailable: Bool = false
    ) async -> [SpeechVoiceInfo] {
        await checkCapabilities().flatMap { snapshot -> [SpeechVoiceInfo] in
            guard let task = snapshot.capabilities.taskCapabilities?.first(where: { $0.kind == "text_to_speech" })
            else { return [] }
            let unavailable = !snapshot.capabilities.available || task.available == false
            guard !unavailable || includeUnavailable else { return [] }
            let declarations = snapshot.descriptor.taskCapabilities?
                .first(where: { $0.kind == "text_to_speech" })?.controls
            return (task.voices ?? [])
                .filter { voice in locale.map { localeMatches(voice, $0, localeMatch) } ?? true }
                .map { voice in
                    SpeechVoiceInfo(
                        providerId: snapshot.providerId,
                        kind: snapshot.descriptor.model == nil ? .platform : .model,
                        model: snapshot.descriptor.model,
                        id: voice.id,
                        name: voice.name,
                        locale: voice.locale,
                        locales: voice.locales,
                        gender: voice.gender,
                        networkRequired: voice.networkRequired,
                        readiness: voice.readiness,
                        controls: includeControls
                            ? voiceControls(declarations, task.controlStates, voice, unavailable: unavailable)
                            : nil,
                        available: unavailable ? false : nil
                    )
                }
        }
    }
}

/// The listed controls of one voice: each `utterance` declaration times each delivery it lists, in
/// declaration order. The merge is the route planner's: the voice's state for `(id, delivery)`
/// overlays the task's, field by field, and a state for an undeclared delivery is never read. An id
/// declared twice, a declaration that breaks its id's invariant (`keepsInvariant`), or two states for
/// one `(id, delivery)` at one level, are contradictory and read `available: false`. Unknown stays
/// `nil`.
private func voiceControls(
    _ declarations: [SpeechControlDeclaration]?,
    _ taskStates: [SpeechControlState]?,
    _ voice: ProviderVoice,
    unavailable: Bool
) -> [SpeechVoiceControl] {
    var controls: [SpeechVoiceControl] = []
    var listed: Set<SpeechControlId> = []
    for declaration in declarations ?? [] where declaration.lifetime == .utterance {
        guard listed.insert(declaration.id).inserted else { continue }
        let contradictory = (declarations ?? []).filter { $0.id == declaration.id }.count > 1
            || !keepsInvariant(declaration)
        for delivery in declaration.deliveries {
            func control(
                available: Bool? = nil,
                reason: String? = nil,
                range: SpeechControlRange? = nil
            ) -> SpeechVoiceControl {
                SpeechVoiceControl(
                    id: declaration.id, delivery: delivery, phase: declaration.phase,
                    available: available, reason: reason, range: range
                )
            }
            if unavailable {
                controls.append(control(available: false))
                continue
            }
            let taskMatches = (taskStates ?? []).filter { $0.id == declaration.id && $0.delivery == delivery }
            let voiceMatches = (voice.controlStates ?? []).filter { $0.id == declaration.id && $0.delivery == delivery }
            if contradictory || taskMatches.count > 1 || voiceMatches.count > 1 {
                controls.append(control(available: false, reason: "contradictory declaration"))
                continue
            }
            let task = taskMatches.first
            let bound = voiceMatches.first
            controls.append(control(
                available: bound?.available ?? task?.available,
                reason: bound?.reason ?? task?.reason,
                range: bound?.range ?? task?.range
            ))
        }
    }
    return controls
}

/// The route planner's declaration invariant (`declaration_keeps_invariant` in the route core), the
/// schema's `allOf` on a control declaration: rate and pitch are `number` controls of the `synthesis`
/// phase, volume a `number` control of the `playback` phase, and a `playback`-phase control lists only
/// the `playback` delivery. A typed declaration can break it without the schema.
private func keepsInvariant(_ declaration: SpeechControlDeclaration) -> Bool {
    let phase: SpeechControlPhase
    switch declaration.id {
    case .speechSpeakingRate, .speechPitch: phase = .synthesis
    case .playbackVolume: phase = .playback
    }
    return declaration.valueKind == .number
        && declaration.phase == phase
        && (phase != .playback || declaration.deliveries.allSatisfy { $0 == .playback })
}
