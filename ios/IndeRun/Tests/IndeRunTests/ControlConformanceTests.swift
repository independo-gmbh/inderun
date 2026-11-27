import Foundation
import XCTest
@testable import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

// MARK: - Catalog access

/// The Apple half of the three ADR 025 scenario catalogs in `contracts/fixtures/execution/`:
/// `control-plan-integrity.json` (a plan inconsistent with the request stops the run before any
/// attempt), `control-outcomes.json` (the engine validates and completes the provider's control
/// records) and `control-execution.json` (plans reach the attempt; commit, fallback and
/// cancellation keep their guarantees). One handler per case id each; the guard tests fail when
/// the handler ids and the catalog ids differ. Mirrors `controls.conformance.test.ts`.
private enum Catalogs {
    typealias JSON = [String: Any]

    static func load(_ name: String) throws -> [JSON] {
        // .../ios/IndeRun/Tests/IndeRunTests/ControlConformanceTests.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("contracts/fixtures/execution/\(name)")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON
        return try XCTUnwrap(root?["cases"] as? [JSON])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }

    /// The JSON object an encodable contract value serializes to, for deep comparison with catalog data.
    static func json<T: Encodable>(_ value: T) throws -> NSObject {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject)
    }

    static func request(_ entry: JSON) throws -> TaskRequest {
        try decode(TaskRequest.self, try XCTUnwrap(entry["request"]))
    }

    static func ids(_ cases: [JSON]) -> [String] {
        cases.compactMap { $0["id"] as? String }.sorted()
    }
}

// MARK: - A one-shot signal

/// Fires once; every waiter, earlier or later, is released.
private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Waits at most `seconds`; false when the signal did not fire in time.
    func wait(seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.wait()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// MARK: - The fake

private enum Step {
    case refuseControl
    case commit
    case reportApplied
    case finish
    case fail
    case waitForCancellation
    /// Reports exactly these records (control-outcomes cases).
    case report([SpeechControlOutcome])
    /// Finishes with exactly these records (control-outcomes cases).
    case finishWith([SpeechControlOutcome])
    /// Finishes with an output that has no speech section (control-outcomes cases).
    case finishWithoutSpeech

    static func named(_ name: String) throws -> Step {
        switch name {
        case "refuse_control": return .refuseControl
        case "commit": return .commit
        case "report_applied": return .reportApplied
        case "finish": return .finish
        case "fail": return .fail
        case "wait_for_cancellation": return .waitForCancellation
        default: throw NSError(domain: "ControlConformanceTests", code: 1, userInfo: ["step": name])
        }
    }

    var waits: Bool {
        if case .waitForCancellation = self { return true }
        return false
    }
}

private let controlRanges: [SpeechControlId: (min: Double, max: Double)] = [
    .speechSpeakingRate: (0.5, 2),
    .speechPitch: (0.5, 2),
    .playbackVolume: (0, 1)
]

/// The record a fake reports for one plan entry: applied as planned, or omitted with its reason.
private func record(for entry: ControlApplicationPlan) -> SpeechControlOutcome {
    switch entry.decision {
    case .apply:
        return SpeechControlOutcome(
            effective: entry.value, id: entry.id, method: controlMethodFor(entry.id), reason: nil,
            requested: entry.value, status: .applied
        )
    case .omit:
        return SpeechControlOutcome(
            effective: nil, id: entry.id, method: nil,
            reason: entry.reason.flatMap { SpeechControlOutcomeReason(rawValue: $0.rawValue) },
            requested: entry.value, status: .notApplied
        )
    }
}

/// A speech provider in the catalogs' vocabulary (see the `$comment` and `$scriptSteps` of
/// `control-execution.json`): it declares the given playback controls with task-level states,
/// lists no voices, and runs its script, recording what it was handed and what `commit()`
/// returned.
private final class ControlFake: StreamingProviderAdapter, @unchecked Sendable {
    let id: String
    private let controls: [SpeechControlId]
    private let script: [Step]
    private let lock = NSLock()
    private var calls = 0
    private var received: [[ControlApplicationPlan]?] = []
    private var commits: [Bool] = []
    /// Fires once the fake has reached `wait_for_cancellation`.
    let waiting = Signal()
    /// Fires when the fake's script has ended, for however long after the run itself ended.
    let done = Signal()

    init(id: String, controls: [SpeechControlId], script: [Step]) {
        self.id = id
        self.controls = controls
        self.script = script
    }

    var callCount: Int { locked { calls } }
    var receivedControls: [[ControlApplicationPlan]?] { locked { received } }
    var commitResults: [Bool] { locked { commits } }
    var waitsForCancellation: Bool { script.contains(where: \.waits) }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .inProcess,
            supports: ProviderSupports(
                run: true, streaming: true, realtime: false, tools: false, reasoningEvents: false,
                structuredOutput: false, multimodal: false
            ),
            cancel: .soft,
            tasks: ["text_to_speech"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_speech",
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(run: true, stream: true),
                    cancel: .soft,
                    outputs: [ProviderTaskOutput(delivery: .playback)],
                    locales: ["de-AT"],
                    controls: controls.isEmpty ? nil : controls.map {
                        SpeechControlDeclaration(
                            deliveries: [.playback], id: $0, lifetime: .utterance,
                            phase: $0 == .playbackVolume ? .playback : .synthesis, valueKind: .number
                        )
                    }
                )
            ],
            privacy: ProviderPrivacy(dataLeavesDevice: false)
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        ProviderDynamicCapabilities(
            available: true,
            taskCapabilities: [
                ProviderTaskAvailability(
                    kind: "text_to_speech",
                    controlStates: controls.isEmpty ? nil : controls.map {
                        SpeechControlState(
                            available: true,
                            delivery: .playback,
                            id: $0,
                            range: SpeechControlRange(
                                speechControlRangeDefault: nil, max: controlRanges[$0]!.max,
                                min: controlRanges[$0]!.min, step: nil
                            ),
                            reason: nil
                        )
                    }
                )
            ]
        )
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        let output = try await play(
            controls: context.controls, commit: context.commit, report: context.reportSpeech, cancellation: nil
        )
        guard let output else {
            throw createInternal(message: "\(id) ended its run without a result")
        }
        return TaskResult(
            runId: context.runId, output: output, finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    func stream(request: TaskRequest, context: ProviderStreamContext) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let output = try await self.play(
                        controls: context.controls, commit: context.commit, report: context.reportSpeech,
                        cancellation: context.cancellation
                    ) {
                        continuation.yield(.result(output: output, finishReason: .stop))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func play(
        controls plan: [ControlApplicationPlan]?,
        commit: @Sendable () -> Bool,
        report: (SpeechOutput) -> Void,
        cancellation: StreamCancellationToken?
    ) async throws -> TaskOutput? {
        defer { done.fire() }
        locked {
            calls += 1
            received.append(plan)
        }
        let entries = plan ?? []
        func finished(_ controls: [SpeechControlOutcome]?) -> TaskOutput {
            TaskOutput(playback: PlaybackOutput(timing: nil), speech: SpeechOutput(controls: controls, locale: "de-AT", voice: nil))
        }
        for step in script {
            switch step {
            case .report(let records):
                report(SpeechOutput(controls: records, locale: "de-AT", voice: nil))
            case .finishWith(let records):
                return finished(records)
            case .finishWithoutSpeech:
                return TaskOutput(playback: PlaybackOutput(timing: nil), speech: nil)
            case .refuseControl:
                throw createCapabilityMismatch(
                    message: "The platform refused a required speech control.",
                    providerId: id,
                    details: ["code": JSONAny("speech_control_unsupported")]
                )
            case .commit:
                let granted = commit()
                locked { commits.append(granted) }
            case .reportApplied:
                let applied = entries.filter { $0.decision == .apply }.map(record(for:))
                report(SpeechOutput(controls: applied, locale: "de-AT", voice: nil))
            case .finish:
                return finished(plan == nil ? nil : entries.map(record(for:)))
            case .fail:
                throw createUnavailable(message: "The fake failed.", providerId: id, retryable: false)
            case .waitForCancellation:
                waiting.fire()
                if let cancellation {
                    await withCheckedContinuation { continuation in cancellation.onCancel { continuation.resume() } }
                }
            }
        }
        return nil
    }
}

// MARK: - Running a case

private enum Mode: String {
    case run
    case stream
}

private struct Observation {
    /// `completed`, `failed` or `cancelled`.
    var outcome: String
    var output: TaskOutput?
    var errorClass: String?
    var errorCode: String?
    var provenance: ExecutionProvenance?
    var eventTypes: [String] = []
}

private func code(of details: [String: JSONAny]?) -> String? {
    details?["code"]?.value as? String
}

private let host = HostServices(connectivity: MockConnectivityService(), clock: MockClockService())

private func engine(_ fakes: [ControlFake], planner: (any RoutePlanning)? = nil) throws -> IndeRun {
    let registry = ProviderRegistry()
    for fake in fakes { try registry.register(fake) }
    guard let planner else { return IndeRun(registry: registry, hostServices: host) }
    return IndeRun(registry: registry, hostServices: host, router: Router(registry: registry, planner: planner))
}

private func failure(_ error: Error) throws -> Observation {
    let exception = try XCTUnwrap(error as? IndeRunException, "\(error)")
    return Observation(
        outcome: "failed", errorClass: exception.errorClass.rawValue, errorCode: code(of: exception.details),
        provenance: exception.provenance
    )
}

/// Runs `request` in `mode`. A stream is drained to its terminal; with `cancelWhen`, it is cancelled
/// once `cancelWhen` resolves.
private func observeRun(
    _ engine: IndeRun,
    _ request: TaskRequest,
    _ mode: Mode,
    cancelWhen: Signal? = nil
) async throws -> Observation {
    switch mode {
    case .run:
        do {
            let result = try await engine.run(request: request)
            return Observation(outcome: "completed", output: result.output, provenance: result.provenance)
        } catch {
            return try failure(error)
        }
    case .stream:
        let run: StreamRun
        do {
            run = try await engine.stream(request: request)
        } catch {
            return try failure(error)
        }
        let draining = Task { () -> [StreamEvent] in
            var events: [StreamEvent] = []
            for try await event in run.events { events.append(event) }
            return events
        }
        if let cancelWhen {
            await cancelWhen.wait()
            run.cancel()
        }
        let events = try await draining.value
        let terminal = try XCTUnwrap(events.last?.payload)
        XCTAssertEqual(events.last?.type, "terminal")
        let outcome = try XCTUnwrap(terminal.outcome)
        return Observation(
            outcome: outcome == .error ? "failed" : outcome.rawValue,
            output: terminal.output,
            errorClass: terminal.error?.errorClass.rawValue,
            errorCode: code(of: terminal.error?.details),
            provenance: terminal.provenance,
            eventTypes: events.map(\.type)
        )
    }
}

// MARK: - The suite

final class ControlConformanceTests: XCTestCase {
    private func steps(_ entry: Catalogs.JSON) throws -> [Step] {
        try (entry["script"] as? [String] ?? []).map(Step.named)
    }

    // MARK: control-plan-integrity.json

    /// A planner that returns the case's candidate(s) verbatim, a missing plan as an absent key.
    private struct InjectedPlanner: RoutePlanning {
        let candidates: [(providerId: String, controls: [ControlApplicationPlan]?)]

        func planRoute(input: SharedPlannerInput) throws -> SharedPlannerRoutePlan {
            let ids = candidates.map(\.providerId)
            return SharedPlannerRoutePlan(
                candidates: candidates.enumerated().map { order, candidate in
                    Candidate(controls: candidate.controls, order: order, providerId: candidate.providerId, voice: nil)
                },
                explanation: SharedPlannerExplanation(selectedProviderId: ids.first, summary: "injected"),
                failureCode: nil,
                fallbackProviderIds: Array(ids.dropFirst()),
                rejectedProviders: [],
                selectedProviderId: ids.first
            )
        }
    }

    private func planControls(_ value: Any?) throws -> [ControlApplicationPlan]? {
        guard let value, !(value is NSNull) else { return nil }
        return try Catalogs.decode([ControlApplicationPlan].self, value)
    }

    private func runPlanIntegrityCase(_ entry: Catalogs.JSON) async throws {
        let request = try Catalogs.request(entry)
        let candidateControls = try planControls(entry["candidateControls"])
        var candidates = [(providerId: "tts", controls: candidateControls)]
        if entry.keys.contains("fallbackCandidateControls") {
            candidates.append((providerId: "tts_fallback", controls: try planControls(entry["fallbackCandidateControls"])))
        }
        let expected = try XCTUnwrap(entry["expected"] as? Catalogs.JSON)
        for mode in [Mode.run, .stream] {
            let fakes = [
                ControlFake(id: "tts", controls: [], script: [.commit, .finish]),
                ControlFake(id: "tts_fallback", controls: [], script: [.commit, .finish])
            ]
            let observation = try await observeRun(
                try engine(fakes, planner: InjectedPlanner(candidates: candidates)), request, mode
            )
            let label = "\(entry["id"] ?? "?") \(mode)"
            if expected["refused"] as? Bool == false {
                XCTAssertEqual(observation.outcome, "completed", label)
                let received = fakes[0].receivedControls
                XCTAssertEqual(received.count, 1, label)
                XCTAssertEqual(
                    try received[0].map(Catalogs.json) ?? NSNull(), try candidateControls.map(Catalogs.json) ?? NSNull(), label
                )
                continue
            }
            XCTAssertEqual(observation.outcome, "failed", label)
            XCTAssertEqual(observation.errorClass, expected["errorClass"] as? String, label)
            XCTAssertEqual(observation.errorCode, expected["detailsCode"] as? String, label)
            XCTAssertEqual(observation.provenance?.attemptCount, expected["attemptCount"] as? Int, label)
            XCTAssertEqual(fakes.map(\.callCount), [0, 0], label)
        }
    }

    private var planIntegrityHandlers: [String: (Catalogs.JSON) async throws -> Void] {
        let handler: (Catalogs.JSON) async throws -> Void = { try await self.runPlanIntegrityCase($0) }
        return Dictionary(uniqueKeysWithValues: [
            "consistent_plan", "no_controls_no_plan", "required_plan_missing", "required_plan_empty",
            "required_plan_omitted", "plan_value_differs", "plan_requirement_differs", "preferred_plan_missing",
            "plan_for_unrequested_control", "plan_without_request", "duplicate_plan_entry",
            "fallback_candidate_inconsistent", "omit_without_reason", "apply_with_reason"
        ].map { ($0, handler) })
    }

    func testImplementsEveryPlanIntegrityCaseAndNoOthers() throws {
        let cases = try Catalogs.load("control-plan-integrity.json")
        XCTAssertFalse(cases.isEmpty)
        XCTAssertEqual(planIntegrityHandlers.keys.sorted(), Catalogs.ids(cases))
    }

    func testMatchesTheSharedPlanIntegrityCatalog() async throws {
        for entry in try Catalogs.load("control-plan-integrity.json") {
            let id = try XCTUnwrap(entry["id"] as? String)
            guard let handler = planIntegrityHandlers[id] else {
                XCTFail("no handler for '\(id)'")
                continue
            }
            try await handler(entry)
        }
    }

    /// Selects a provider but lists no candidate for it. The router then attempts a candidate it
    /// synthesizes without a plan, so the plan check has to cover what is attempted, not only what
    /// the plan lists.
    private struct SelectedWithoutCandidatePlanner: RoutePlanning {
        func planRoute(input: SharedPlannerInput) throws -> SharedPlannerRoutePlan {
            SharedPlannerRoutePlan(
                candidates: [],
                explanation: SharedPlannerExplanation(selectedProviderId: "tts", summary: "injected"),
                failureCode: nil,
                fallbackProviderIds: [],
                rejectedProviders: [],
                selectedProviderId: "tts"
            )
        }
    }

    func testASynthesizedCandidateWithoutAPlanIsRefusedBeforeAnyAttempt() async throws {
        let entry = try XCTUnwrap(
            try Catalogs.load("control-plan-integrity.json").first { $0["id"] as? String == "required_plan_missing" }
        )
        let request = try Catalogs.request(entry)
        for mode in [Mode.run, .stream] {
            let fake = ControlFake(id: "tts", controls: [], script: [.commit, .finish])
            let observation = try await observeRun(
                try engine([fake], planner: SelectedWithoutCandidatePlanner()), request, mode
            )
            XCTAssertEqual(observation.outcome, "failed", "\(mode)")
            XCTAssertEqual(observation.errorClass, "Internal", "\(mode)")
            XCTAssertEqual(observation.errorCode, "control_plan_mismatch", "\(mode)")
            XCTAssertEqual(observation.provenance?.attemptCount, 0, "\(mode)")
            XCTAssertEqual(fake.callCount, 0, "\(mode)")
        }
    }

    // MARK: control-outcomes.json

    private let allControls: [SpeechControlId] = [.speechSpeakingRate, .speechPitch, .playbackVolume]

    private func reportedRecords(_ entry: Catalogs.JSON) throws -> [SpeechControlOutcome] {
        try Catalogs.decode([SpeechControlOutcome].self, try XCTUnwrap(entry["reported"]))
    }

    /// A completed run (both modes) whose provider reports the case's records in its output.
    private func runCompletedOutcomeCase(_ entry: Catalogs.JSON) async throws {
        let request = try Catalogs.request(entry)
        let reported = try reportedRecords(entry)
        let expected = try XCTUnwrap(entry["expected"] as? Catalogs.JSON)
        for mode in [Mode.run, .stream] {
            let label = "\(entry["id"] ?? "?") \(mode)"
            let fake = ControlFake(id: "tts", controls: allControls, script: [.commit, .finishWith(reported)])
            let observation = try await observeRun(try engine([fake]), request, mode)
            // The helper the engine calls gives the same answer on its own.
            let direct = Result {
                try completeControlOutcomes(request: request, reported: reported, ending: .completed, providerId: "tts")
            }
            if expected["failed"] as? Bool == true {
                XCTAssertEqual(observation.outcome, "failed", label)
                XCTAssertEqual(observation.errorClass, expected["errorClass"] as? String, label)
                XCTAssertEqual(observation.errorCode, expected["detailsCode"] as? String, label)
                guard case .failure(let error) = direct else { return XCTFail("\(label): helper accepted the records") }
                XCTAssertEqual((error as? IndeRunException)?.errorClass, .Internal, label)
            } else {
                XCTAssertEqual(observation.outcome, "completed", label)
                let controls = try XCTUnwrap(expected["controls"], label)
                XCTAssertEqual(try Catalogs.json(try XCTUnwrap(observation.output?.speech?.controls)), controls as? NSObject, label)
                XCTAssertEqual(try Catalogs.json(try direct.get()), controls as? NSObject, label)
            }
            // Nothing is replayed after a failure that followed the commit.
            XCTAssertEqual(fake.callCount, 1, label)
        }
    }

    /// A completed run (both modes) whose provider's output has no speech section at all.
    private func runNoSpeechSectionCase(_ entry: Catalogs.JSON) async throws {
        let request = try Catalogs.request(entry)
        XCTAssertTrue(entry["reported"] is NSNull)
        let expected = try XCTUnwrap(entry["expected"] as? Catalogs.JSON)
        let bare = TaskOutput(playback: PlaybackOutput(timing: nil), speech: nil)
        for mode in [Mode.run, .stream] {
            let label = "\(entry["id"] ?? "?") \(mode)"
            let fake = ControlFake(id: "tts", controls: allControls, script: [.commit, .finishWithoutSpeech])
            let observation = try await observeRun(try engine([fake]), request, mode)
            let direct = Result { try completeOutputControls(request: request, output: bare, providerId: "tts") }
            if expected["failed"] as? Bool == true {
                XCTAssertEqual(observation.outcome, "failed", label)
                XCTAssertEqual(observation.errorClass, expected["errorClass"] as? String, label)
                XCTAssertEqual(observation.errorCode, expected["detailsCode"] as? String, label)
                guard case .failure(let error) = direct else { return XCTFail("\(label): helper accepted the output") }
                XCTAssertEqual((error as? IndeRunException)?.errorClass, .Internal, label)
            } else {
                // Passed unchanged: no section is invented, so there are no records either.
                XCTAssertNil(expected["controls"], label)
                XCTAssertEqual(observation.outcome, "completed", label)
                XCTAssertNil(observation.output?.speech, label)
                XCTAssertNil(try direct.get().speech, label)
            }
            XCTAssertEqual(fake.callCount, 1, label)
        }
    }

    /// A cancelled stream whose provider reported the case's records before the stop.
    private func runCancelledOutcomeCase(_ entry: Catalogs.JSON) async throws {
        let request = try Catalogs.request(entry)
        let reported = try reportedRecords(entry)
        let expected = try XCTUnwrap(entry["expected"] as? Catalogs.JSON)
        let fake = ControlFake(id: "tts", controls: allControls, script: [.commit, .report(reported), .waitForCancellation])
        let observation = try await observeRun(try engine([fake]), request, .stream, cancelWhen: fake.waiting)
        XCTAssertEqual(expected["failed"] as? Bool, false)
        XCTAssertEqual(observation.outcome, "cancelled")
        let controls = expected["controls"] as? NSObject
        XCTAssertEqual(try Catalogs.json(try XCTUnwrap(observation.output?.speech?.controls)), controls)
        let direct = try completeControlOutcomes(request: request, reported: reported, ending: .cancelled, providerId: "tts")
        XCTAssertEqual(try Catalogs.json(direct), controls)
    }

    private var outcomeHandlers: [String: (Catalogs.JSON) async throws -> Void] {
        let completed: (Catalogs.JSON) async throws -> Void = { try await self.runCompletedOutcomeCase($0) }
        var handlers = Dictionary(uniqueKeysWithValues: [
            "complete_records", "preferred_record_missing", "required_record_missing", "required_not_applied",
            "duplicate_record", "unrequested_record", "requested_value_differs", "volume_reported_as_synthesis"
        ].map { ($0, completed) })
        handlers["cancelled_keeps_known_records"] = { try await self.runCancelledOutcomeCase($0) }
        for id in ["preferred_only_no_speech_section", "required_no_speech_section"] {
            handlers[id] = { try await self.runNoSpeechSectionCase($0) }
        }
        return handlers
    }

    func testImplementsEveryOutcomeCaseAndNoOthers() throws {
        let cases = try Catalogs.load("control-outcomes.json")
        XCTAssertFalse(cases.isEmpty)
        XCTAssertEqual(outcomeHandlers.keys.sorted(), Catalogs.ids(cases))
    }

    func testMatchesTheSharedOutcomeCatalog() async throws {
        for entry in try Catalogs.load("control-outcomes.json") {
            let id = try XCTUnwrap(entry["id"] as? String)
            guard let handler = outcomeHandlers[id] else {
                XCTFail("no handler for '\(id)'")
                continue
            }
            try await handler(entry)
        }
    }

    // MARK: control-execution.json

    private func runExecutionCase(_ entry: Catalogs.JSON) async throws {
        let request = try Catalogs.request(entry)
        let expected = try XCTUnwrap(entry["expect"] as? Catalogs.JSON)
        let modes = try XCTUnwrap(entry["modes"] as? [String]).compactMap(Mode.init(rawValue:))
        for mode in modes {
            let label = "\(entry["id"] ?? "?") \(mode)"
            let fakes = try XCTUnwrap(entry["providers"] as? [Catalogs.JSON]).map { provider in
                ControlFake(
                    id: provider["id"] as? String ?? "",
                    controls: (provider["controls"] as? [String] ?? []).compactMap(SpeechControlId.init(rawValue:)),
                    script: try steps(provider)
                )
            }
            func fake(_ id: String) throws -> ControlFake { try XCTUnwrap(fakes.first { $0.id == id }, label) }
            let cancelWhen = entry["cancelWhen"] as? String == "waiting"
                ? fakes.first(where: \.waitsForCancellation)?.waiting
                : nil
            let observation = try await observeRun(try engine(fakes), request, mode, cancelWhen: cancelWhen)
            // The stream may end as soon as the cancel lands: let every fake finish its script first.
            for entered in fakes where entered.callCount > 0 {
                let finishedInTime = await entered.done.wait(seconds: 5)
                XCTAssertTrue(finishedInTime, "\(label): \(entered.id) did not finish its script")
            }
            let provenance = try XCTUnwrap(observation.provenance, label)

            XCTAssertEqual(observation.outcome, expected["outcome"] as? String, label)
            if let errorClass = expected["errorClass"] as? String {
                XCTAssertEqual(observation.errorClass, errorClass, label)
            }
            for (id, count) in expected["providerCallCounts"] as? [String: Int] ?? [:] {
                XCTAssertEqual(try fake(id).callCount, count, "\(label) \(id) calls")
            }
            for (id, controls) in expected["receivedControls"] as? Catalogs.JSON ?? [:] {
                let received = try fake(id).receivedControls
                XCTAssertEqual(received.count, 1, "\(label) \(id) controls")
                XCTAssertEqual(try received.first??.map(Catalogs.json), controls as? [NSObject], "\(label) \(id) controls")
            }
            if let attempts = expected["attempts"] as? [[String]] {
                XCTAssertEqual(provenance.attempts.map { [$0.providerId, $0.outcome.rawValue] }, attempts, label)
            }
            for (id, errorClass) in expected["attemptErrorClasses"] as? [String: String] ?? [:] {
                XCTAssertEqual(provenance.attempts.first { $0.providerId == id }?.errorClass?.rawValue, errorClass, label)
            }
            if let committed = expected["committedAttempts"] as? [String] {
                XCTAssertEqual(provenance.attempts.filter { $0.committed == true }.map(\.providerId), committed, label)
            }
            if let fallback = expected["fallbackOccurred"] as? Bool {
                XCTAssertEqual(provenance.fallbackOccurred, fallback, label)
            }
            for (id, results) in expected["commitResults"] as? [String: [Bool]] ?? [:] {
                XCTAssertEqual(try fake(id).commitResults, results, "\(label) \(id) commits")
            }
            if let output = expected["output"] {
                XCTAssertEqual(try Catalogs.json(try XCTUnwrap(observation.output, label)), output as? NSObject, label)
            }
            if expected["absentOutput"] as? Bool == true {
                XCTAssertNil(observation.output, label)
            }
            if let types = expected["eventTypes"] as? [String], mode == .stream {
                XCTAssertEqual(observation.eventTypes, types, label)
            }
        }
    }

    private var executionHandlers: [String: (Catalogs.JSON) async throws -> Void] {
        let handler: (Catalogs.JSON) async throws -> Void = { try await self.runExecutionCase($0) }
        return Dictionary(uniqueKeysWithValues: [
            "precommit_control_refusal_falls_back_once", "postcommit_failure_is_not_replayed",
            "cancel_before_commit_runs_nothing", "cancel_after_commit_keeps_known_records",
            "late_callback_after_cancel_is_suppressed", "plan_reaches_provider"
        ].map { ($0, handler) })
    }

    func testImplementsEveryExecutionCaseAndNoOthers() throws {
        let cases = try Catalogs.load("control-execution.json")
        XCTAssertFalse(cases.isEmpty)
        XCTAssertEqual(executionHandlers.keys.sorted(), Catalogs.ids(cases))
    }

    func testMatchesTheSharedExecutionCatalog() async throws {
        for entry in try Catalogs.load("control-execution.json") {
            let id = try XCTUnwrap(entry["id"] as? String)
            guard let handler = executionHandlers[id] else {
                XCTFail("no handler for '\(id)'")
                continue
            }
            try await handler(entry)
        }
    }

    // MARK: Beyond the catalogs

    private func executionRequest(_ id: String) throws -> TaskRequest {
        let entry = try XCTUnwrap(try Catalogs.load("control-execution.json").first { $0["id"] as? String == id })
        return try Catalogs.request(entry)
    }

    private func outcomeRequest(_ id: String) throws -> TaskRequest {
        let entry = try XCTUnwrap(try Catalogs.load("control-outcomes.json").first { $0["id"] as? String == id })
        return try Catalogs.request(entry)
    }

    private var plainRequest: TaskRequest {
        TaskRequest(
            task: TaskDescriptor(kind: .textToSpeech),
            speech: SpeechInput(controls: nil, locale: "de-AT", localeMatch: nil, text: "Guten Morgen!", voice: nil),
            delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: nil, mode: .playback, playback: nil)
        )
    }

    /// A required control no provider supports is a routing rejection: it reaches the error's
    /// details and the provenance, and no attempt is made (ADR 025 section 2).
    func testFailsCapabilityMismatchWhenNoProviderSupportsARequiredControl() async throws {
        let request = try executionRequest("postcommit_failure_is_not_replayed")
        for mode in [Mode.run, .stream] {
            let fake = ControlFake(id: "tts", controls: [], script: [.commit, .finish])
            let observation = try await observeRun(try engine([fake]), request, mode)
            XCTAssertEqual(observation.outcome, "failed", "\(mode)")
            XCTAssertEqual(observation.errorClass, "CapabilityMismatch", "\(mode)")
            let provenance = try XCTUnwrap(observation.provenance)
            XCTAssertEqual(provenance.attemptCount, 0, "\(mode)")
            XCTAssertEqual(provenance.routeRejections.map(\.providerId), ["tts"], "\(mode)")
            XCTAssertTrue(provenance.routeRejections.first?.codes.contains(.speechControlUnsupported) ?? false, "\(mode)")
            XCTAssertEqual(fake.callCount, 0)
        }
    }

    func testRouteRejectionCodeReachesTheErrorDetails() async throws {
        let request = try executionRequest("postcommit_failure_is_not_replayed")
        let fake = ControlFake(id: "tts", controls: [], script: [.commit, .finish])
        do {
            _ = try await engine([fake]).run(request: request)
            XCTFail("expected a routing failure")
        } catch let error as IndeRunException {
            let rejected = try XCTUnwrap(error.details?["rejectedProviders"]?.value as? [[String: Any]])
            XCTAssertEqual(rejected.first?["providerId"] as? String, "tts")
            let reasons = try XCTUnwrap(rejected.first?["reasons"] as? [[String: Any]])
            XCTAssertTrue(reasons.contains { $0["code"] as? String == "speech_control_unsupported" })
        }
    }

    func testLeavesARequestWithoutControlsExactlyAsBefore() async throws {
        let fake = ControlFake(id: "tts", controls: allControls, script: [.commit, .finish])
        let observation = try await observeRun(try engine([fake]), plainRequest, .run)
        XCTAssertEqual(fake.receivedControls.count, 1)
        XCTAssertNil(fake.receivedControls.first ?? nil)
        let output = try XCTUnwrap(observation.output)
        XCTAssertEqual(try Catalogs.json(output), ["type": "playback", "playback": [:], "speech": ["locale": "de-AT"]] as NSObject)
    }

    func testRefusesRecordsOnARequestWithoutControls() async throws {
        let records = [
            SpeechControlOutcome(
                effective: 1, id: .speechPitch, method: .platformSynthesis, reason: nil, requested: 1, status: .applied
            )
        ]
        let fake = ControlFake(id: "tts", controls: allControls, script: [.commit, .finishWith(records)])
        let observation = try await observeRun(try engine([fake]), plainRequest, .run)
        XCTAssertEqual(observation.outcome, "failed")
        XCTAssertEqual(observation.errorCode, "output_mismatch")
    }

    func testRefusesACompletedOutputWithoutASpeechSectionWhenTheRequestHasControls() throws {
        let request = try outcomeRequest("preferred_record_missing")
        let output = TaskOutput(playback: PlaybackOutput(timing: nil))
        XCTAssertThrowsError(try completeOutputControls(request: request, output: output, providerId: "tts")) { error in
            XCTAssertEqual((error as? IndeRunException)?.errorClass, .Internal)
            XCTAssertEqual(code(of: (error as? IndeRunException)?.details), "output_mismatch")
        }
    }

    func testRefusesAnAppliedRecordWithoutAMethodAndANotAppliedRecordWithoutAReason() throws {
        let request = try outcomeRequest("preferred_record_missing")
        let noMethod = SpeechControlOutcome(
            effective: 0.85, id: .speechSpeakingRate, method: nil, reason: nil, requested: 0.85, status: .applied
        )
        let noReason = SpeechControlOutcome(
            effective: nil, id: .speechPitch, method: nil, reason: nil, requested: 1.05, status: .notApplied
        )
        for record in [noMethod, noReason] {
            XCTAssertThrowsError(
                try completeControlOutcomes(request: request, reported: [record], ending: .cancelled, providerId: "tts"),
                "\(record.id)"
            )
        }
    }

    /// An output_mismatch on control records before the attempt committed is a provider fault that
    /// may fall back, like every other output check.
    func testFallsBackFromAnUncommittedAttemptWhoseControlRecordsBreakTheRules() async throws {
        let request = try outcomeRequest("preferred_record_missing")
        let broken = [
            SpeechControlOutcome(
                effective: 0.85, id: .speechSpeakingRate, method: .playbackAttenuation, reason: nil, requested: 0.85,
                status: .applied
            )
        ]
        for mode in [Mode.run, .stream] {
            let a = ControlFake(id: "a_primary", controls: allControls, script: [.finishWith(broken)])
            let b = ControlFake(id: "b_secondary", controls: allControls, script: [.commit, .finish])
            let observation = try await observeRun(try engine([a, b]), request, mode)
            XCTAssertEqual(observation.outcome, "completed", "\(mode)")
            XCTAssertEqual(
                observation.provenance?.attempts.map { [$0.providerId, $0.outcome.rawValue] },
                [["a_primary", "failed"], ["b_secondary", "succeeded"]],
                "\(mode)"
            )
        }
    }

    func testDropsAReportThatBreaksTheRecordRulesFromACancelledTerminal() async throws {
        let request = try outcomeRequest("cancelled_keeps_known_records")
        let broken = [
            SpeechControlOutcome(
                effective: 0.85, id: .speechSpeakingRate, method: .playbackAttenuation, reason: nil, requested: 0.85,
                status: .applied
            )
        ]
        let fake = ControlFake(id: "tts", controls: allControls, script: [.commit, .report(broken), .waitForCancellation])
        let observation = try await observeRun(try engine([fake]), request, .stream, cancelWhen: fake.waiting)
        XCTAssertEqual(observation.outcome, "cancelled")
        let controls = try XCTUnwrap(observation.output?.speech?.controls)
        XCTAssertEqual(controls.map(\.id), [.speechSpeakingRate, .speechPitch, .playbackVolume])
        XCTAssertEqual(controls.map(\.status), [.notApplied, .notApplied, .notApplied])
        XCTAssertEqual(controls.map(\.reason), [.notReported, .notReported, .notReported])
    }

    func testACancelledRunWhoseProviderNeverReportedCarriesNoSpeechSection() async throws {
        let request = try outcomeRequest("cancelled_keeps_known_records")
        let fake = ControlFake(id: "tts", controls: allControls, script: [.commit, .waitForCancellation])
        let observation = try await observeRun(try engine([fake]), request, .stream, cancelWhen: fake.waiting)
        XCTAssertEqual(observation.outcome, "cancelled")
        XCTAssertNil(observation.output?.speech)
    }

    func testRunContextReportSpeechIsANoOpByDefault() {
        let context = RunContext(runId: "r", hostServices: host)
        XCTAssertNil(context.controls)
        context.reportSpeech(SpeechOutput(controls: nil, locale: "de-AT", voice: nil))
    }
}
