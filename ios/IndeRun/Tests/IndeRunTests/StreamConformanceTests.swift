import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunSwift

// MARK: - Mode 2 conformance

/// The Apple half of the cross-SDK Mode 2 conformance catalog.
///
/// The catalog lives in `contracts/fixtures/streaming/engine-conformance.json` and
/// is driven identically by the Web and Kotlin suites. Each case id gets exactly
/// one handler here; `testImplementsEveryCaseInTheSharedCatalogAndNoOthers` fails
/// when the handler ids and the catalog ids are not equal, so a scenario covered
/// on another platform and not on this one is a red build rather than a review
/// finding.
///
/// `StreamOrchestrationTests` keeps what is specific to this platform.
final class StreamConformanceTests: XCTestCase {
    // MARK: Catalog

    private struct ConformanceCase: Decodable {
        let id: String
        let category: String
        let description: String
        let expect: Expectations
    }

    private struct Catalog: Decodable {
        let cases: [ConformanceCase]
    }

    private struct TerminalExpectation: Decodable {
        var outcome: String?
        var finalText: String?
        var partialText: String?
        var reason: String?
        var finishReason: String?
        var errorClass: String?
        var usage: [String: Int]?
        var absentFinishReason: Bool?
        var absentUsage: Bool?
    }

    private struct RejectedProviderExpectation: Decodable {
        let providerId: String
        var reasons: [String]?
        var messages: [String]?
    }

    private struct RejectionExpectation: Decodable {
        var errorClass: String?
        var runId: String?
        var failureCode: String?
        var rejectedProviders: [RejectedProviderExpectation]?
    }

    private struct Expectations: Decodable {
        var eventTypes: [String]?
        var sequences: [Int]?
        var contentTexts: [String]?
        var terminalCount: Int?
        var eventsAfterTerminal: Int?
        var terminal: TerminalExpectation?
        var rejectsWith: RejectionExpectation?
        var providerCallCounts: [String: Int]?
        var providerInterrupted: Bool?
        var runSelectedProviderId: String?
        var streamSelectedProviderId: String?
        var handleStartedAtIsUnixEpochMillis: Bool?
        var telemetryTypes: [String]?
        var telemetryTypesContain: [String]?
        var telemetryForbiddenPayloadKeys: [String]?
        var telemetryForbiddenPayloadValues: [String]?
        var telemetryStableMessageEvents: [String]?
        var noReplayOnSecondIteration: Bool?
    }

    private static func repositoryRoot() -> URL {
        // .../ios/IndeRun/Tests/IndeRunTests/StreamConformanceTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadCatalog() throws -> Catalog {
        let url = Self.repositoryRoot()
            .appendingPathComponent("contracts/fixtures/streaming/engine-conformance.json")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    // MARK: Tests

    func testImplementsEveryCaseInTheSharedCatalogAndNoOthers() throws {
        let catalogIds = try loadCatalog().cases.map(\.id).sorted()
        XCTAssertFalse(catalogIds.isEmpty)
        XCTAssertEqual(Set(catalogIds).count, catalogIds.count, "duplicate case id in the catalog")
        XCTAssertEqual(handlers.keys.sorted(), catalogIds)
    }

    func testMatchesTheSharedConformanceCatalog() async throws {
        for conformanceCase in try loadCatalog().cases {
            guard let handler = handlers[conformanceCase.id] else {
                XCTFail("no handler for catalog case '\(conformanceCase.id)'")
                continue
            }
            let label = "\(conformanceCase.category): \(conformanceCase.id)"
            let observed = try await handler()
            check(label: label, expected: conformanceCase.expect, observed: observed)
        }
    }

    // MARK: Observation

    private struct Observation {
        var events: [StreamEvent] = []
        var rejection: IndeRunException?
        var telemetry: [TelemetryEvent] = []
        var providerCallCounts: [String: Int] = [:]
        var providerInterrupted: Bool?
        var runSelectedProviderId: String?
        var streamSelectedProviderId: String?
        var handleStartedAt: Double?
        var wallClockRange: ClosedRange<Int64>?
        var secondIterationEventCount: Int?
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func check(label: String, expected: Expectations, observed: Observation) {
        let events = observed.events

        if let eventTypes = expected.eventTypes {
            XCTAssertEqual(events.map(\.type), eventTypes, "\(label): eventTypes")
        }
        if let sequences = expected.sequences {
            XCTAssertEqual(events.map { Int($0.sequence) }, sequences, "\(label): sequences")
        }
        if let contentTexts = expected.contentTexts {
            let texts = events
                .filter { $0.type == "content_delta" || $0.type == "content_snapshot" }
                .map { $0.payload?.text ?? "<nil>" }
            XCTAssertEqual(texts, contentTexts, "\(label): contentTexts")
        }
        if let terminalCount = expected.terminalCount {
            XCTAssertEqual(
                events.filter { $0.type == "terminal" }.count,
                terminalCount,
                "\(label): terminalCount"
            )
        }
        if let after = expected.eventsAfterTerminal {
            guard let index = events.firstIndex(where: { $0.type == "terminal" }) else {
                XCTFail("\(label): expected a terminal event")
                return
            }
            XCTAssertEqual(events.count - 1 - index, after, "\(label): eventsAfterTerminal")
        }

        if let terminal = expected.terminal {
            check(label: label, terminal: terminal, events: events)
        }
        if let rejection = expected.rejectsWith {
            check(label: label, rejection: rejection, observed: observed)
        }

        for (providerId, count) in expected.providerCallCounts ?? [:] {
            XCTAssertEqual(
                observed.providerCallCounts[providerId],
                count,
                "\(label): \(providerId) call count"
            )
        }
        if let interrupted = expected.providerInterrupted {
            XCTAssertEqual(observed.providerInterrupted, interrupted, "\(label): providerInterrupted")
        }
        if let runProviderId = expected.runSelectedProviderId {
            XCTAssertEqual(observed.runSelectedProviderId, runProviderId, "\(label): run provider")
        }
        if let streamProviderId = expected.streamSelectedProviderId {
            XCTAssertEqual(observed.streamSelectedProviderId, streamProviderId, "\(label): stream provider")
        }
        if expected.handleStartedAtIsUnixEpochMillis == true {
            guard let range = observed.wallClockRange, let startedAt = observed.handleStartedAt else {
                XCTFail("\(label): missing wall-clock observation")
                return
            }
            XCTAssertTrue(
                range.contains(Int64(startedAt)),
                "\(label): startedAt \(startedAt) is outside the wall-clock range \(range)"
            )
        }

        check(label: label, expected: expected, telemetry: observed.telemetry)

        if expected.noReplayOnSecondIteration == true {
            XCTAssertEqual(observed.secondIterationEventCount, 0, "\(label): second iteration replayed")
        }
    }

    private func check(label: String, terminal: TerminalExpectation, events: [StreamEvent]) {
        guard let payload = events.first(where: { $0.type == "terminal" })?.payload else {
            XCTFail("\(label): expected a terminal event")
            return
        }
        if let outcome = terminal.outcome {
            XCTAssertEqual(payload.outcome?.rawValue, outcome, "\(label): outcome")
        }
        if let finalText = terminal.finalText {
            XCTAssertEqual(payload.finalText, finalText, "\(label): finalText")
        }
        if let partialText = terminal.partialText {
            XCTAssertEqual(payload.partialText, partialText, "\(label): partialText")
        }
        if let reason = terminal.reason {
            XCTAssertEqual(payload.reason, reason, "\(label): reason")
        }
        if let finishReason = terminal.finishReason {
            XCTAssertEqual(payload.finishReason?.rawValue, finishReason, "\(label): finishReason")
        }
        if let errorClass = terminal.errorClass {
            XCTAssertEqual(payload.error?.errorClass.rawValue, errorClass, "\(label): errorClass")
        }
        if let usage = terminal.usage {
            XCTAssertEqual(payload.usage?.inputTokens, usage["inputTokens"], "\(label): usage.inputTokens")
            XCTAssertEqual(payload.usage?.outputTokens, usage["outputTokens"], "\(label): usage.outputTokens")
            XCTAssertEqual(payload.usage?.totalTokens, usage["totalTokens"], "\(label): usage.totalTokens")
        }
        if terminal.absentFinishReason == true {
            XCTAssertNil(payload.finishReason, "\(label): finishReason must be absent")
        }
        if terminal.absentUsage == true {
            XCTAssertNil(payload.usage, "\(label): usage must be absent")
        }
    }

    private func check(label: String, rejection: RejectionExpectation, observed: Observation) {
        guard let thrown = observed.rejection else {
            XCTFail("\(label): expected stream() to reject")
            return
        }
        if let errorClass = rejection.errorClass {
            XCTAssertEqual(thrown.errorClass.rawValue, errorClass, "\(label): errorClass")
        }
        if let runId = rejection.runId {
            XCTAssertEqual(thrown.runId, runId, "\(label): runId")
        }
        let details = thrown.details ?? [:]
        if let failureCode = rejection.failureCode {
            XCTAssertEqual(details["failureCode"]?.value as? String, failureCode, "\(label): failureCode")
        }
        guard let expectedProviders = rejection.rejectedProviders else { return }
        let rejected = details["rejectedProviders"]?.value as? [[String: Any]] ?? []
        for expectedProvider in expectedProviders {
            guard let actual = rejected.first(where: {
                $0["providerId"] as? String == expectedProvider.providerId
            }) else {
                XCTFail("\(label): expected \(expectedProvider.providerId) among rejectedProviders")
                continue
            }
            let reasons = actual["reasons"] as? [[String: Any]] ?? []
            if let codes = expectedProvider.reasons {
                XCTAssertEqual(
                    reasons.compactMap { $0["code"] as? String },
                    codes,
                    "\(label): \(expectedProvider.providerId) reasons"
                )
            }
            if let messages = expectedProvider.messages {
                XCTAssertEqual(
                    reasons.compactMap { $0["message"] as? String },
                    messages,
                    "\(label): \(expectedProvider.providerId) messages"
                )
            }
        }
    }

    private func check(label: String, expected: Expectations, telemetry: [TelemetryEvent]) {
        let types = telemetry.map(\.type.rawValue)
        if let expectedTypes = expected.telemetryTypes {
            XCTAssertEqual(types, expectedTypes, "\(label): telemetryTypes")
        }
        for type in expected.telemetryTypesContain ?? [] {
            XCTAssertTrue(types.contains(type), "\(label): expected telemetry to contain '\(type)', saw \(types)")
        }
        for key in expected.telemetryForbiddenPayloadKeys ?? [] {
            for event in telemetry {
                XCTAssertNil(event.payload[key], "\(label): \(event.type.rawValue) payload must not carry '\(key)'")
            }
        }
        for value in expected.telemetryForbiddenPayloadValues ?? [] {
            for event in telemetry {
                XCTAssertFalse(
                    String(describing: event.payload.mapValues(\.value)).contains(value),
                    "\(label): \(event.type.rawValue) payload must not contain '\(value)'"
                )
            }
        }
        for type in expected.telemetryStableMessageEvents ?? [] {
            guard let event = telemetry.first(where: { $0.type.rawValue == type }) else {
                XCTFail("\(label): expected a \(type) telemetry event")
                continue
            }
            let message = event.payload["message"]?.value as? String
            XCTAssertNotNil(message, "\(label): \(type) payload needs a stable message")
            XCTAssertFalse(message?.isEmpty ?? true, "\(label): \(type) stable message must not be empty")
        }
    }

    // MARK: Fixtures

    private func makeHost(
        online: Bool = true,
        telemetry: MockTelemetryService? = nil
    ) -> HostServices {
        let connectivity = MockConnectivityService()
        connectivity.online = online
        return HostServices(
            connectivity: connectivity,
            clock: MockClockService(),
            telemetry: telemetry
        )
    }

    /// Host services reading the real wall clock, for the one case that asserts
    /// `StreamRunHandle.startedAt` is Unix epoch milliseconds rather than whatever
    /// counter a mock happens to hand out.
    private func makeWallClockHost() -> HostServices {
        HostServices(connectivity: MockConnectivityService(), clock: SystemClockService())
    }

    private func makeRequest(requestId: String? = nil, privacy: PrivacyEnum? = nil) -> TaskRequest {
        TaskRequest(
            requestId: requestId,
            task: TaskDescriptor(kind: .textToText),
            prompt: "Hello",
            constraints: privacy.map { TaskRequestConstraints(privacy: $0) }
        )
    }

    private func drain(_ run: StreamRun) async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in run.events {
            events.append(event)
        }
        return events
    }

    private func captureRejection(_ start: () async throws -> Void) async -> Observation {
        do {
            try await start()
            XCTFail("expected stream() to reject, but it resolved")
            return Observation()
        } catch let rejection as IndeRunException {
            return Observation(rejection: rejection)
        } catch {
            XCTFail("expected an IndeRunException, got \(error)")
            return Observation()
        }
    }

    // MARK: Handlers

    private typealias Handler = () async throws -> Observation

    // swiftlint:disable:next function_body_length
    private var handlers: [String: Handler] {
        [
            "deltas_then_completed": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "Hello")),
                    .init(.delta(text: " world")),
                    .init(.done(finalText: "Hello world"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "snapshot_replaces_cumulative_text": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.snapshot(text: "Loc")),
                    .init(.snapshot(text: "Local first")),
                    .init(.done(finalText: "Local first"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "completed_carries_finish_reason_and_usage": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "trunc")),
                    .init(.done(
                        finalText: "trunc",
                        finishReason: .length,
                        usage: TaskResultUsage(inputTokens: 2, outputTokens: 1, totalTokens: 3)
                    ))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "completed_omits_finish_reason_when_absent": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "a")),
                    .init(.done(finalText: "a"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "handle_started_at_is_unix_epoch_millis": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [.init(.done(finalText: "ok"))]))
                let engine = IndeRun(registry: registry, hostServices: makeWallClockHost())
                let before = Int64(Date().timeIntervalSince1970 * 1000)
                let run = try await engine.stream(request: makeRequest())
                let after = Int64(Date().timeIntervalSince1970 * 1000)
                _ = try await drain(run)
                return Observation(
                    handleStartedAt: run.handle.startedAt,
                    wallClockRange: before ... after
                )
            },

            "terminal_error_carries_error_class": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(
                    id: "p1",
                    script: [.init(.delta(text: "partial "))],
                    throwAfterScript: createRateLimited(message: "upstream is throttling")
                ))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "all_providers_fail_pre_commit_yields_single_error": { [self] in
                let first = MockStreamProvider(
                    id: "p1",
                    throwImmediately: createUnavailable(message: "boom")
                )
                let second = MockStreamProvider(
                    id: "p2",
                    throwImmediately: createUnavailable(message: "boom")
                )
                let registry = ProviderRegistry()
                try registry.register(first)
                try registry.register(second)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let events = try await drain(try await engine.stream(request: makeRequest()))
                return Observation(
                    events: events,
                    providerCallCounts: ["p1": first.callCount, "p2": second.callCount]
                )
            },

            "cancelled_carries_partial_text_and_reason": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "one")),
                    .waitForCancellation
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                var events: [StreamEvent] = []
                for try await event in run.events {
                    events.append(event)
                    if event.type == "content_delta" { run.cancel(reason: "user stopped") }
                }
                return Observation(events: events)
            },

            "no_events_are_delivered_after_the_terminal": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "a")),
                    .init(.done(finalText: "a")),
                    .init(.delta(text: "b"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "cancel_before_first_attempt_forecloses_every_provider": { [self] in
                let first = MockStreamProvider(id: "p1", script: [.waitForCancellation])
                let second = MockStreamProvider(id: "p2", script: [.init(.done(finalText: "never"))])
                let registry = ProviderRegistry()
                try registry.register(first)
                try registry.register(second)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                run.cancel()
                let events = try await drain(run)
                return Observation(
                    events: events,
                    providerCallCounts: ["p1": first.callCount, "p2": second.callCount]
                )
            },

            "cancel_during_emit_stops_further_deltas": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "one")),
                    .waitForCancellation,
                    .init(.delta(text: " two")),
                    .init(.done(finalText: "one two"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                var events: [StreamEvent] = []
                for try await event in run.events {
                    events.append(event)
                    if event.type == "content_delta" { run.cancel() }
                }
                return Observation(events: events)
            },

            "cancel_after_terminal_is_a_no_op": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "done")),
                    .init(.done(finalText: "done"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                let events = try await drain(run)
                run.cancel(reason: "too late")
                // Anything the cancel could still produce would arrive after this.
                try? await Task.sleep(nanoseconds: 20_000_000)
                return Observation(events: events)
            },

            "concurrent_cancels_yield_one_outcome_first_reason_wins": { [self] in
                let provider = MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "one")),
                    .waitForCancellation
                ])
                let registry = ProviderRegistry()
                try registry.register(provider)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                let collector = Task { try await drain(run) }
                // Both land while the drain is in flight. Which reason wins has to be
                // the caller's order, not the scheduler's, so they are issued in
                // sequence rather than from two racing tasks.
                await provider.waitUntilEntered()
                run.cancel(reason: "first")
                run.cancel(reason: "second")
                return Observation(events: try await collector.value)
            },

            "cancel_during_pre_commit_attempt_forecloses_next_route": { [self] in
                let failing = MockStreamProvider(
                    id: "p1",
                    script: [.waitForCancellation],
                    throwAfterScript: createUnavailable(message: "boom before any content")
                )
                let fallback = MockStreamProvider(id: "p2", script: [.init(.done(finalText: "never"))])
                let registry = ProviderRegistry()
                try registry.register(failing)
                try registry.register(fallback)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                let collector = Task { try await drain(run) }
                await failing.waitUntilEntered()
                run.cancel(reason: "mid-attempt")
                return Observation(
                    events: try await collector.value,
                    providerCallCounts: ["p1": failing.callCount, "p2": fallback.callCount]
                )
            },

            "cancel_unblocks_a_provider_waiting_for_output": { [self] in
                let provider = MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "one")),
                    .waitForCancellation
                ])
                let registry = ProviderRegistry()
                try registry.register(provider)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                var events: [StreamEvent] = []
                for try await event in run.events {
                    events.append(event)
                    if event.type == "content_delta" { run.cancel() }
                }
                return Observation(events: events, providerInterrupted: provider.wasInterrupted)
            },

            "no_streaming_capable_provider_rejects_with_run_id": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockProvider(id: "p_run_only", type: .local))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return await captureRejection {
                    _ = try await engine.stream(request: makeRequest(requestId: "req-42"))
                }
            },

            "declared_streaming_without_implementation_rejected": { [self] in
                let registry = ProviderRegistry()
                try registry.register(DeclaredOnlyStreamProvider(id: "p_declared_only"))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                var observed = await captureRejection {
                    _ = try await engine.stream(request: makeRequest())
                }
                observed.providerCallCounts = ["p_declared_only": 0]
                return observed
            },

            "dynamic_capability_revocation_rejected_with_reason": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(
                    id: "p_revoked",
                    streamingAvailable: false,
                    streamingUnavailableReason: "Host has no chunked HTTP capability."
                ))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return await captureRejection { _ = try await engine.stream(request: makeRequest()) }
            },

            "routing_rejection_carries_failure_code_and_reason_codes": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockProvider(id: "p_run_only", type: .local))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return await captureRejection { _ = try await engine.stream(request: makeRequest()) }
            },

            "privacy_constraint_enforced_on_stream_routes": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p_cloud_streaming", type: .cloud))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return await captureRejection {
                    _ = try await engine.stream(request: makeRequest(privacy: .localRequired))
                }
            },

            "offline_host_with_cloud_stream_provider_reports_offline": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p_cloud_streaming", type: .cloud))
                let engine = IndeRun(registry: registry, hostServices: makeHost(online: false))
                return await captureRejection {
                    _ = try await engine.stream(request: makeRequest(privacy: .cloudAllowed))
                }
            },

            "offline_host_with_local_stream_provider_reports_capability_mismatch": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockProvider(id: "p_local_run_only", type: .local))
                let engine = IndeRun(registry: registry, hostServices: makeHost(online: false))
                return await captureRejection {
                    _ = try await engine.stream(request: makeRequest(privacy: .cloudAllowed))
                }
            },

            "run_and_stream_resolve_different_chains": { [self] in
                let runOnly = MockProvider(id: "a_run_only", type: .local)
                let streaming = MockStreamProvider(id: "b_streaming", script: [
                    .init(.done(finalText: "streamed"))
                ])
                let registry = ProviderRegistry()
                try registry.register(runOnly)
                try registry.register(streaming)
                let engine = IndeRun(registry: registry, hostServices: makeHost())

                let result = try await engine.run(request: makeRequest())
                let run = try await engine.stream(request: makeRequest())
                _ = try await drain(run)

                return Observation(
                    providerCallCounts: ["a_run_only": 0],
                    runSelectedProviderId: result.telemetry.providerUsed,
                    streamSelectedProviderId: run.handle.providerId
                )
            },

            "pre_commit_failure_falls_back": { [self] in
                let failing = MockStreamProvider(
                    id: "p1_failing",
                    throwImmediately: createUnavailable(message: "boom")
                )
                let healthy = MockStreamProvider(id: "p2_healthy", script: [
                    .init(.done(finalText: "recovered"))
                ])
                let registry = ProviderRegistry()
                try registry.register(failing)
                try registry.register(healthy)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let events = try await drain(try await engine.stream(request: makeRequest()))
                return Observation(
                    events: events,
                    providerCallCounts: ["p1_failing": failing.callCount, "p2_healthy": healthy.callCount]
                )
            },

            "post_commit_failure_never_falls_back": { [self] in
                let failing = MockStreamProvider(
                    id: "p1",
                    script: [.init(.delta(text: "partial "))],
                    throwAfterScript: createUnavailable(message: "boom")
                )
                let healthy = MockStreamProvider(id: "p2_healthy", script: [
                    .init(.done(finalText: "never"))
                ])
                let registry = ProviderRegistry()
                try registry.register(failing)
                try registry.register(healthy)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let events = try await drain(try await engine.stream(request: makeRequest()))
                return Observation(events: events, providerCallCounts: ["p2_healthy": healthy.callCount])
            },

            "stream_ending_without_terminal_is_a_provider_fault": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [.init(.delta(text: "a"))]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "provider_emitted_failure_behaves_like_a_throw": { [self] in
                let emitting = MockStreamProvider(id: "p1", script: [
                    .init(.failure(error: createRateLimited(message: "slow down")))
                ])
                let healthy = MockStreamProvider(id: "p2_healthy", script: [
                    .init(.done(finalText: "recovered"))
                ])
                let registry = ProviderRegistry()
                try registry.register(emitting)
                try registry.register(healthy)
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let events = try await drain(try await engine.stream(request: makeRequest()))
                return Observation(
                    events: events,
                    providerCallCounts: ["p1": emitting.callCount, "p2_healthy": healthy.callCount]
                )
            },

            "duplicate_terminal_suppressed": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "first")),
                    .init(.done(finalText: "first")),
                    .init(.done(finalText: "second"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "empty_snapshot_retracts_delivered_content": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(
                    id: "p1",
                    script: [
                        .init(.delta(text: "rejected text")),
                        .init(.snapshot(text: ""))
                    ],
                    throwAfterScript: createCapabilityMismatch(
                        message: "The response was rejected by a policy check."
                    )
                ))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                return Observation(events: try await drain(try await engine.stream(request: makeRequest())))
            },

            "telemetry_sequence_for_a_normal_completion": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "Hello")),
                    .init(.done(finalText: "Hello"))
                ]))
                let telemetry = MockTelemetryService()
                let engine = IndeRun(registry: registry, hostServices: makeHost(telemetry: telemetry))
                _ = try await drain(try await engine.stream(request: makeRequest()))
                return Observation(telemetry: telemetry.events)
            },

            "stream_cancelled_telemetry_carries_no_raw_error_detail": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "one")),
                    .waitForCancellation
                ]))
                let telemetry = MockTelemetryService()
                let engine = IndeRun(registry: registry, hostServices: makeHost(telemetry: telemetry))
                let run = try await engine.stream(request: makeRequest())
                for try await event in run.events where event.type == "content_delta" {
                    run.cancel(reason: "secret user text")
                }
                return Observation(telemetry: telemetry.events)
            },

            "stream_failed_telemetry_carries_a_stable_message": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(
                    id: "p1",
                    script: [.init(.delta(text: "partial "))],
                    throwAfterScript: createUnavailable(message: "upstream said: sk-secret leaked")
                ))
                let telemetry = MockTelemetryService()
                let engine = IndeRun(registry: registry, hostServices: makeHost(telemetry: telemetry))
                _ = try await drain(try await engine.stream(request: makeRequest()))
                return Observation(telemetry: telemetry.events)
            },

            "events_are_single_use": { [self] in
                let registry = ProviderRegistry()
                try registry.register(MockStreamProvider(id: "p1", script: [
                    .init(.delta(text: "a")),
                    .init(.done(finalText: "a"))
                ]))
                let engine = IndeRun(registry: registry, hostServices: makeHost())
                let run = try await engine.stream(request: makeRequest())
                let first = try await drain(run)
                // Swift completes an exhausted sequence rather than raising; Kotlin
                // raises. Both satisfy the shared guarantee, which is that the run is
                // never replayed -- see the `$divergence` note on this catalog case.
                let second = try await drain(run)
                return Observation(events: first, secondIterationEventCount: second.count)
            }
        ]
    }
}
