import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

/// The voices each attempt was handed, in attempt order, across both interaction modes.
private final class VoiceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProviderVoice?] = []

    var voices: [ProviderVoice?] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func record(_ voice: ProviderVoice?) {
        lock.lock()
        entries.append(voice)
        lock.unlock()
    }
}

/// A local speech provider that lists `voices` and records the voice each attempt receives.
private final class SpeechProvider: StreamingProviderAdapter, @unchecked Sendable {
    let id: String
    let voices: [ProviderVoice]
    let log: VoiceLog

    init(id: String, voices: [ProviderVoice], log: VoiceLog) {
        self.id = id
        self.voices = voices
        self.log = log
    }

    func describe() -> ProviderDescriptor {
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
            tasks: ["text_to_speech"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_speech",
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(run: true, stream: true),
                    cancel: .hard,
                    outputs: [ProviderTaskOutput(delivery: .playback)],
                    locales: ["de-AT", "de-DE"]
                )
            ],
            privacy: ProviderPrivacy(dataLeavesDevice: false)
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(
            available: true,
            taskCapabilities: [ProviderTaskAvailability(kind: "text_to_speech", voices: voices)]
        )
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        log.record(context.voice)
        return TaskResult(
            runId: context.runId,
            output: TaskOutput(playback: PlaybackOutput(durationMs: nil)),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    func stream(request: TaskRequest, context: ProviderStreamContext)
        -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        log.record(context.voice)
        return AsyncThrowingStream { continuation in
            continuation.yield(.done(finalText: ""))
            continuation.finish()
        }
    }
}

/// Binds every provider, in id order, to the first voice it lists. The shared planner never
/// binds a network voice under `local_required`, so this plan exercises the engine's own
/// pre-attempt check. (The registry does not keep registration order.)
private struct FirstVoicePlanner: RoutePlanning {
    func planRoute(input: SharedPlannerInput) throws -> SharedPlannerRoutePlan {
        let providers = input.providers.sorted { $0.descriptor.id < $1.descriptor.id }
        let ids = providers.map(\.descriptor.id)
        return SharedPlannerRoutePlan(
            candidates: providers.enumerated().map { order, provider in
                Candidate(
                    order: order,
                    providerId: provider.descriptor.id,
                    voice: provider.capabilities.taskCapabilities?.first?.voices?.first
                )
            },
            explanation: SharedPlannerExplanation(selectedProviderId: ids.first, summary: "injected"),
            failureCode: nil,
            fallbackProviderIds: Array(ids.dropFirst()),
            rejectedProviders: [],
            selectedProviderId: ids.first
        )
    }
}

/// The task-profile table (#245): requests are checked against their kind's rules, each
/// attempt is handed the voice the plan bound, and that voice is re-checked against the
/// privacy policy immediately before the attempt. Mirrors `task-profiles.test.ts`.
final class TaskProfileTests: XCTestCase {
    private let host = HostServices(connectivity: MockConnectivityService(), clock: MockClockService())

    private func speechRequest(privacy: Privacy = .localRequired) -> TaskRequest {
        TaskRequest(
            task: TaskDescriptor(kind: .textToSpeech),
            constraints: TaskRequestConstraints(privacy: privacy),
            speech: SpeechInput(
                locale: "de-AT",
                localeMatch: nil,
                text: "Hallo",
                voice: SpeechVoice(gender: .female, requirement: nil)
            ),
            delivery: OutputDeliveryRequest(mediaTypes: nil, mode: .playback)
        )
    }

    /// An engine whose plan binds each provider to its first listed voice.
    private func engineBindingFirstVoices(_ registry: ProviderRegistry) -> IndeRun {
        IndeRun(
            registry: registry,
            hostServices: host,
            router: Router(registry: registry, planner: FirstVoicePlanner())
        )
    }

    // MARK: - Bound voice

    func testHandsEachAttemptTheVoiceThePlanBoundForItsProvider() async throws {
        let log = VoiceLog()
        let registry = ProviderRegistry()
        try registry.register(SpeechProvider(
            id: "local_speech",
            voices: [ProviderVoice(locale: "de-DE", gender: .male), ProviderVoice(locale: "de-AT", gender: .female)],
            log: log
        ))

        let result = try await IndeRun(registry: registry, hostServices: host).run(request: speechRequest())

        XCTAssertEqual(result.telemetry.providerUsed, "local_speech")
        XCTAssertEqual(log.voices.count, 1)
        XCTAssertEqual(log.voices.first??.locale, "de-AT")
        XCTAssertEqual(log.voices.first??.gender, .female)
    }

    func testRefusesANetworkVoiceUnderLocalRequiredBeforeTheAttemptAndFallsBack() async throws {
        let log = VoiceLog()
        let registry = ProviderRegistry()
        try registry.register(SpeechProvider(
            id: "a_bound_to_network",
            voices: [ProviderVoice(locale: "de-AT", networkRequired: true)],
            log: log
        ))
        try registry.register(SpeechProvider(id: "b_local", voices: [ProviderVoice(locale: "de-AT")], log: log))

        let result = try await engineBindingFirstVoices(registry).run(request: speechRequest())

        XCTAssertEqual(log.voices.map { $0?.locale }, ["de-AT"])
        XCTAssertEqual(log.voices.first??.networkRequired, nil)
        let attempts = try XCTUnwrap(result.provenance?.attempts)
        XCTAssertEqual(attempts.map(\.providerId), ["a_bound_to_network", "b_local"])
        XCTAssertEqual(attempts.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(attempts.first?.errorClass, .CapabilityMismatch)
    }

    func testStreamRefusesANetworkVoiceUnderLocalRequiredBeforeTheAttemptAndFallsBack() async throws {
        let log = VoiceLog()
        let registry = ProviderRegistry()
        try registry.register(SpeechProvider(
            id: "a_bound_to_network",
            voices: [ProviderVoice(locale: "de-AT", networkRequired: true)],
            log: log
        ))
        try registry.register(SpeechProvider(id: "b_local", voices: [ProviderVoice(locale: "de-AT")], log: log))

        let run = try await engineBindingFirstVoices(registry).stream(request: speechRequest())
        var terminal: StreamEvent?
        for try await event in run.events { terminal = event }

        XCTAssertEqual(log.voices.map { $0?.locale }, ["de-AT"])
        let attempts = try XCTUnwrap(terminal?.payload?.provenance?.attempts)
        XCTAssertEqual(attempts.map(\.providerId), ["a_bound_to_network", "b_local"])
        XCTAssertEqual(attempts.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(attempts.first?.errorClass, .CapabilityMismatch)
    }

    func testAllowsANetworkVoiceWhenTheRequestDoesNotRequireLocalExecution() throws {
        let voice = ProviderVoice(locale: "de-AT", networkRequired: true)

        let refusal = try XCTUnwrap(recheckBoundVoice(request: speechRequest(), providerId: "p", voice: voice))
        XCTAssertEqual(refusal.errorClass, .CapabilityMismatch)
        XCTAssertEqual(refusal.details?["code"]?.value as? String, "privacy_recheck_failed")
        XCTAssertNil(recheckBoundVoice(request: speechRequest(privacy: .localPreferred), providerId: "p", voice: voice))
        XCTAssertNil(recheckBoundVoice(request: speechRequest(), providerId: "p", voice: ProviderVoice(locale: "de-AT")))
        XCTAssertNil(recheckBoundVoice(request: speechRequest(), providerId: "p", voice: nil))
    }

    // MARK: - Validation

    private func validationMessage(for request: TaskRequest) async -> String? {
        let registry = ProviderRegistry()
        try? registry.register(SpeechProvider(id: "local_speech", voices: [], log: VoiceLog()))
        do {
            _ = try await IndeRun(registry: registry, hostServices: host).run(request: request)
            return nil
        } catch let error as IndeRunException {
            return error.message.contains("Validation failed") ? error.message : nil
        } catch {
            return nil
        }
    }

    func testValidSpeechRequestPassesValidation() async {
        let message = await validationMessage(for: speechRequest())
        XCTAssertNil(message)
    }

    func testSpeechRequestWithoutSpeechFailsValidation() async {
        var request = speechRequest()
        request.speech = nil

        let message = await validationMessage(for: request)
        XCTAssertTrue(message?.contains("speech must be provided for task.kind 'text_to_speech'") == true, "\(message ?? "nil")")
    }

    func testSpeechRequestWithAPromptFailsValidation() async {
        var request = speechRequest()
        request.prompt = "Hallo"

        let message = await validationMessage(for: request)
        XCTAssertTrue(message?.contains("prompt must not be set for task.kind 'text_to_speech'") == true, "\(message ?? "nil")")
    }

    func testSpeechRequestDeliveryAndVoiceRulesAreEnforced() {
        var request = speechRequest()
        request.speech?.text = ""
        request.speech?.voice = SpeechVoice(gender: nil, requirement: .requirementLevelRequired)
        request.delivery = OutputDeliveryRequest(mediaTypes: ["audio/wav"], mode: .inline)

        let issues = TaskProfiles.profile(for: .textToSpeech).validate(request)

        XCTAssertEqual(issues, [
            "speech.text must be non-empty.",
            "speech.voice.gender must be provided when speech.voice.requirement is 'required'.",
            "delivery.mode must be 'playback' or 'artifact' for task.kind 'text_to_speech'.",
            "delivery.mediaTypes is only valid with 'artifact' delivery."
        ])
    }

    func testTextRequestWithSpeechPayloadFailsValidation() {
        var request = speechRequest()
        request.task = TaskDescriptor(kind: .textToText)
        request.prompt = "Hallo"

        let issues = TaskProfiles.profile(for: .textToText).validate(request)

        XCTAssertEqual(issues, [
            "speech must not be set for task.kind 'text_to_text'.",
            "delivery must not be set for task.kind 'text_to_text'."
        ])
    }
}
