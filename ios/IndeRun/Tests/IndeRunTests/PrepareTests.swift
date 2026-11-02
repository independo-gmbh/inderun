import IndeRunContracts
import IndeRunCore
@testable import IndeRunSwift
import XCTest

/// Mirrors `engine.prepare.test.ts`: the same rules, over a fake provider that counts calls.
private final class FakeProvider: PreparableProviderAdapter, @unchecked Sendable {
    private let id: String
    private let work: @Sendable () async throws -> Void
    private let lock = NSLock()
    private var readiness: ProviderReadiness
    private var prepareCalls = 0
    private var runCalls = 0
    private var capabilityCalls = 0

    var prepares: Int { lock.withLock { prepareCalls } }
    var capabilityChecks: Int { lock.withLock { capabilityCalls } }
    var runs: Int { lock.withLock { runCalls } }

    init(_ id: String, _ readiness: ProviderReadiness, work: @escaping @Sendable () async throws -> Void = {}) {
        self.id = id
        self.readiness = readiness
        self.work = work
    }

    func describe() -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            type: .local,
            transport: .inProcess,
            supports: ProviderSupports(
                run: true,
                streaming: false,
                realtime: false,
                tools: false,
                reasoningEvents: false,
                structuredOutput: false,
                multimodal: false
            ),
            cancel: .soft,
            tasks: ["text_to_text"],
            taskCapabilities: [
                ProviderTaskCapability(
                    kind: "text_to_text",
                    inputs: [.text],
                    interaction: ProviderTaskInteraction(prepare: true, run: true, stream: false),
                    cancel: .soft,
                    outputs: [ProviderTaskOutput(delivery: .inline)]
                )
            ]
        )
    }

    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities {
        let current = lock.withLock {
            capabilityCalls += 1
            return readiness
        }
        return ProviderDynamicCapabilities(
            available: current == .ready || current == .cold,
            taskCapabilities: [ProviderTaskAvailability(kind: "text_to_text", readiness: current)]
        )
    }

    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult {
        lock.withLock { runCalls += 1 }
        return TaskResult(
            runId: context.runId,
            output: TaskOutput(text: "ok"),
            finishReason: .stop,
            telemetry: TelemetryInfo(providerUsed: id, totalMs: 0)
        )
    }

    func prepare(context: ProviderPrepareContext) -> AsyncThrowingStream<PreparationProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                self.lock.withLock { self.prepareCalls += 1 }
                continuation.yield(PreparationProgress(fractionCompleted: 0.5))
                do {
                    try await self.work()
                    self.lock.withLock { self.readiness = .ready }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class PrepareTests: XCTestCase {
    private let text = TaskRequest(prompt: "Hi")

    private func engine(_ providers: [FakeProvider], autoDownload: Bool = false) throws -> IndeRun {
        let registry = ProviderRegistry()
        for provider in providers {
            try registry.register(provider, options: ProviderRegistrationOptions(autoDownload: autoDownload))
        }
        return IndeRun(
            registry: registry,
            hostServices: HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
        )
    }

    func testRunsOnceOnTheFirstCallWhenTheApplicationNeverCalledIt() async throws {
        let provider = FakeProvider("a", .preparing)
        let inderun = try engine([provider])

        _ = try await inderun.run(request: text)
        _ = try await inderun.run(request: text)

        XCTAssertEqual(provider.prepares, 1)
        XCTAssertEqual(provider.runs, 2)
    }

    func testIsSkippedOnTheFirstCallAfterAnExplicitPrepare() async throws {
        let provider = FakeProvider("a", .cold)
        let inderun = try engine([provider])

        _ = try await inderun.prepare().result()
        _ = try await inderun.run(request: text)

        XCTAssertEqual(provider.prepares, 1)
    }

    func testSharesOnePreparationBetweenConcurrentFirstCalls() async throws {
        let provider = FakeProvider("a", .preparing) { try await Task.sleep(nanoseconds: 50_000_000) }
        let inderun = try engine([provider])

        async let first = inderun.run(request: text)
        async let second = inderun.run(request: text)
        _ = try await (first, second)

        XCTAssertEqual(provider.prepares, 1)
    }

    func testLeavesAColdProviderAloneOnTheFirstCall() async throws {
        let provider = FakeProvider("a", .cold)

        _ = try await engine([provider]).run(request: text)

        XCTAssertEqual(provider.prepares, 0)
        XCTAssertEqual(provider.runs, 1)
    }

    func testNeverStartsADownloadWithoutPermission() async throws {
        let provider = FakeProvider("a", .notPrepared)

        let result = try await engine([provider]).prepare().result()

        XCTAssertEqual(provider.prepares, 0)
        XCTAssertEqual(result.items.map(\.status), [.skipped])
    }

    func testDownloadsOnTheFirstCallUnderAutoDownloadThenRuns() async throws {
        let provider = FakeProvider("a", .notPrepared)

        _ = try await engine([provider], autoDownload: true).run(request: text)

        XCTAssertEqual(provider.prepares, 1)
        XCTAssertEqual(provider.runs, 1)
    }

    func testLetsOneCallAllowADownload() async throws {
        let provider = FakeProvider("a", .notPrepared)

        _ = try await engine([provider]).prepare(PrepareRequest(allowDownload: true)).result()

        XCTAssertEqual(provider.prepares, 1)
    }

    func testGivesUpWaitingAtTheBoundSoRoutingCanFallBack() async throws {
        let stuck = FakeProvider("a", .notPrepared) { try await Task.sleep(nanoseconds: 60_000_000_000) }
        let fallback = FakeProvider("b", .ready)
        var request = text
        request.constraints = TaskRequestConstraints(cloud: nil, privacy: nil, timeoutMs: 10)

        let result = try await engine([stuck, fallback], autoDownload: true).run(request: request)

        XCTAssertEqual(result.telemetry.providerUsed, "b")
    }

    func testKeepsGoingWhenOneProviderFails() async throws {
        let broken = FakeProvider("a", .cold) { throw CocoaError(.fileNoSuchFile) }
        let healthy = FakeProvider("b", .cold)

        let result = try await engine([broken, healthy]).prepare().result()

        XCTAssertEqual(Set(result.items.map(\.status)), [.failed, .prepared])
    }

    func testCancelsWithOneTerminalOutcome() async throws {
        let provider = FakeProvider("a", .preparing) { try await Task.sleep(nanoseconds: 60_000_000_000) }
        let preparation = try await engine([provider]).prepare()
        try await Task.sleep(nanoseconds: 20_000_000)

        preparation.cancel(reason: "left the screen")
        preparation.cancel(reason: "again")

        let cancelled = try await preparation.result().cancelled
        XCTAssertTrue(cancelled)
    }

    /// Polls instead of sleeping a fixed time, because a slow runner stretches every step.
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<2000 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }

    /// Starts a preparation that stays in the provider, then a second one, and returns once the
    /// second has planned, so it can only join the first.
    private func overlappingPreparations(
        _ provider: FakeProvider,
        _ inderun: IndeRun
    ) async throws -> (first: Preparation, second: Preparation) {
        let first = try await inderun.prepare()
        try await waitUntil { provider.prepares == 1 }
        let checks = provider.capabilityChecks
        let second = try await inderun.prepare()
        try await waitUntil { provider.capabilityChecks > checks }
        try await Task.sleep(nanoseconds: 100_000_000)
        return (first, second)
    }

    func testSharesAFailureWithACallerThatWaitedForTheSamePreparation() async throws {
        let release = Attempts()
        let provider = FakeProvider("a", .cold) {
            while release.current == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            throw CocoaError(.fileNoSuchFile)
        }
        let inderun = try engine([provider])

        let (first, second) = try await overlappingPreparations(provider, inderun)
        _ = release.next()

        let firstItems = try await first.result().items
        let secondItems = try await second.result().items
        XCTAssertEqual(firstItems.map(\.status), [.failed])
        XCTAssertEqual(secondItems.map(\.status), [.failed])
        XCTAssertEqual(provider.prepares, 1)
    }

    func testCancellingAWaitingCallerStopsItWithoutCancellingTheOther() async throws {
        let release = Attempts()
        let provider = FakeProvider("a", .cold) {
            while release.current == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let inderun = try engine([provider])
        let (first, second) = try await overlappingPreparations(provider, inderun)

        second.cancel(reason: "left the screen")
        let cancelled = try await second.result().cancelled

        // It ended while the other preparation was still held, so it did not wait for it.
        XCTAssertTrue(cancelled)
        XCTAssertEqual(release.current, 0)
        _ = release.next()
        let firstItems = try await first.result().items
        XCTAssertEqual(firstItems.map(\.status), [.prepared])
    }

    func testASkippedPreparationDoesNotCountAsDoneForAFirstRunThatMayDownload() async throws {
        let provider = FakeProvider("a", .notPrepared)
        let inderun = try engine([provider], autoDownload: true)

        _ = try await inderun.prepare(PrepareRequest(allowDownload: false)).result()
        _ = try await inderun.run(request: text)

        XCTAssertEqual(provider.prepares, 1)
        XCTAssertEqual(provider.runs, 1)
    }

    func testAFailedPreparationDoesNotCountAsDone() async throws {
        let attempts = Attempts()
        let provider = FakeProvider("a", .preparing) {
            if attempts.next() == 1 { throw CocoaError(.fileNoSuchFile) }
        }
        let inderun = try engine([provider])

        _ = try await inderun.prepare().result()
        _ = try await inderun.run(request: text)

        XCTAssertEqual(provider.prepares, 2)
    }
}

private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var current: Int { lock.withLock { count } }

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
