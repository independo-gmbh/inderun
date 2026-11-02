import Foundation
import IndeRunContracts
import IndeRunCore

/// How long a first run waits for preparation when its request sets no `timeoutMs`.
private let defaultFirstRunPrepareMs = 30_000

/// The engine's half of ADR 019: what is prepared, and how a preparation runs. Lives apart from
/// `IndeRun` because a preparation shares none of a run's fallback or commit rules.
actor Preparer {
    private let registry: ProviderRegistry
    private let router: Router
    private let hostServices: HostServices
    private var preparedScopes: Set<String> = []
    private var firstRuns: [String: Task<Void, Never>] = [:]
    private var running: [String: SharedPreparation] = [:]

    init(registry: ProviderRegistry, router: Router, hostServices: HostServices) {
        self.registry = registry
        self.router = router
        self.hostServices = hostServices
    }

    /// The task kinds a registered provider declares it can prepare, within `tasks` when given.
    /// Asks no provider anything, so a request with nothing to prepare costs nothing.
    nonisolated func preparableKinds(_ tasks: [String]?) -> [String] {
        let kinds = registry.list()
            .flatMap { $0.describe().taskCapabilities ?? [] }
            .filter { $0.interaction.prepare == true }
            .map(\.kind)
        return Array(Set(kinds)).sorted().filter { tasks?.contains($0) ?? true }
    }

    /// Remembers what is really ready: a skipped or failed item must get its next chance.
    func markPrepared(_ kinds: [String], request: PrepareRequest, items: [PreparationItem]) {
        for kind in kinds where items.filter({ $0.task == kind }).allSatisfy({
            $0.status == .prepared || $0.status == .alreadyReady
        }) {
            preparedScopes.insert(scope(kind, request.locale, request.voice?.id))
        }
    }

    /// What a preparation covered. A voice or locale is a scope of its own: having prepared
    /// `de-DE` says nothing about the voice a run for `en-US` needs.
    private func scope(_ kind: String, _ locale: String?, _ voiceId: String?) -> String {
        "\(kind)|\(locale ?? "")|\(voiceId ?? "")"
    }

    /// Prepares what `request` needs before its first run, once per task kind: it waits for what is
    /// loading and starts a download only under `autoDownload`. A `cold` item is left alone, because
    /// a cold run warms itself and warming first would be slower. Bounded, and never a failure: when
    /// this ends, normal routing decides, with its own fallback and refusals.
    func beforeFirstRun(_ request: TaskRequest, runId: String) async {
        let kind = request.task.kind.rawValue
        let speech = request.speech
        let key = scope(kind, speech?.locale, speech?.voice?.id)
        guard !preparedScopes.contains(key), !preparableKinds([kind]).isEmpty else { return }
        if let first = firstRuns[key] {
            await first.value
            return
        }

        let scope = PrepareRequest(
            tasks: [kind],
            locale: speech?.locale,
            localeMatch: speech?.localeMatch,
            voice: speech?.voice.map { PrepareVoice(gender: $0.gender, id: $0.id, providerId: $0.providerId) },
            privacy: request.constraints?.privacy
        )
        let boundMs = request.constraints?.timeoutMs ?? defaultFirstRunPrepareMs
        let first = Task {
            let work = Task { _ = await self.prepare(scope, runId: runId, firstRun: true) { _, _, _ in } }
            // Raced, because a provider that ignores cancellation must not hold the bound hostage.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let finish = ResumeOnce(continuation)
                Task {
                    await work.value
                    finish.resume()
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(boundMs) * 1_000_000)
                    work.cancel()
                    finish.resume()
                }
            }
            self.finishFirstRun(key)
        }
        firstRuns[key] = first
        await first.value
    }

    /// Once per scope, whatever came of it: routing answers from here on.
    private func finishFirstRun(_ key: String) {
        preparedScopes.insert(key)
        firstRuns[key] = nil
    }

    /// Prepares each provider and task in scope, reporting progress, and returns one item for each.
    func prepare(
        _ request: PrepareRequest,
        runId: String,
        firstRun: Bool,
        onProgress: @Sendable (String, String, Double?) -> Void
    ) async -> [PreparationItem] {
        var items: [PreparationItem] = []
        for task in preparableKinds(request.tasks) {
            let candidates: [PreparationCandidate]
            do {
                candidates = try await router.planPreparation(
                    task: plannerTask(task, request),
                    privacy: request.privacy,
                    hostServices: hostServices
                )
            } catch {
                continue
            }

            for candidate in candidates {
                guard !Task.isCancelled else { return items }
                let providerId = candidate.provider.describe().id
                let voiceId = candidate.voice?.id
                func item(_ status: PreparationStatus, reason: String? = nil) -> PreparationItem {
                    PreparationItem(providerId: providerId, reason: reason, status: status, task: task, voiceId: voiceId)
                }

                if candidate.readiness == .ready || (firstRun && candidate.readiness == .cold) {
                    items.append(item(.alreadyReady))
                    continue
                }
                let allowed = request.allowDownload ?? registry.allowsAutoDownload(id: providerId)
                if candidate.readiness == .notPrepared, !allowed {
                    items.append(item(
                        .skipped,
                        reason: "A download is needed, and neither autoDownload nor allowDownload permits it."
                    ))
                    continue
                }

                let key = "\(providerId)|\(task)|\(voiceId ?? "")"
                if let earlier = running[key] {
                    guard let shared = await earlier.wait() else { return items }
                    items.append(item(shared.status, reason: shared.reason))
                    continue
                }

                let shared = SharedPreparation()
                running[key] = shared
                var outcome = PreparationOutcome(status: .failed, reason: "The preparation was stopped.")
                do {
                    let context = ProviderPrepareContext(
                        runId: runId,
                        hostServices: hostServices,
                        task: task,
                        locale: request.locale,
                        voice: candidate.voice
                    )
                    for try await progress in candidate.provider.prepare(context: context) {
                        onProgress(providerId, task, progress.fractionCompleted)
                    }
                    if !Task.isCancelled {
                        outcome = PreparationOutcome(status: .prepared, reason: nil)
                        items.append(item(.prepared))
                    }
                } catch {
                    if !Task.isCancelled {
                        let exception = toIndeRunException(error, fallbackRunId: runId, fallbackProviderId: providerId)
                        outcome = PreparationOutcome(status: .failed, reason: exception.message)
                        items.append(item(.failed, reason: exception.message))
                    }
                }
                running[key] = nil
                shared.finish(outcome)
            }
        }
        return items
    }

    private func plannerTask(_ kind: String, _ request: PrepareRequest) -> RoutePlannerInputTask {
        RoutePlannerInputTask(
            delivery: nil,
            inputs: [.text],
            kind: kind,
            locale: request.locale.map { LocaleRequirement(match: request.localeMatch ?? .language, tag: $0) },
            voice: request.voice.map {
                VoiceRequirement(gender: $0.gender, id: $0.id, providerId: $0.providerId, requirement: .preferred)
            }
        )
    }
}

/// How one provider's preparation ended, shared with callers that waited for it.
private struct PreparationOutcome: Sendable {
    let status: PreparationStatus
    let reason: String?
}

/// One provider's preparation under way, so a second caller shares its outcome. A caller that is
/// cancelled stops waiting at once and leaves the preparation running for the others.
private final class SharedPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: PreparationOutcome?
    private var waiters: [UUID: CheckedContinuation<PreparationOutcome?, Never>] = [:]

    /// Returns the outcome, or `nil` when the calling task was cancelled first.
    func wait() async -> PreparationOutcome? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let settled: (Bool, PreparationOutcome?) = lock.withLock {
                    if let outcome { return (true, outcome) }
                    if Task.isCancelled { return (true, nil) }
                    waiters[id] = continuation
                    return (false, nil)
                }
                if settled.0 { continuation.resume(returning: settled.1) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(returning: nil)
        }
    }

    func finish(_ outcome: PreparationOutcome) {
        let pending = lock.withLock {
            self.outcome = outcome
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in pending { waiter.resume(returning: outcome) }
    }
}

/// Resumes a continuation once, whichever side gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

/// How a `prepare` run ended. One failed item does not fail the run.
public struct PreparationResult: Sendable {
    /// `true` when the run was stopped.
    public let cancelled: Bool
    public let items: [PreparationItem]
    public let runId: String
}

/// What `prepare` returns: a handle on a preparation in progress.
public struct Preparation: Sendable {
    public let runId: String
    private let task: Task<PreparationResult, Error>
    private let cancellation: @Sendable (String?) -> Void

    fileprivate init(
        runId: String,
        task: Task<PreparationResult, Error>,
        cancel: @escaping @Sendable (String?) -> Void
    ) {
        self.runId = runId
        self.task = task
        self.cancellation = cancel
    }

    /// Returns when done or stopped. Throws only when the run itself fails.
    public func result() async throws -> PreparationResult {
        try await task.value
    }

    /// Stops waiting; idempotent. A platform download already started may go on.
    public func cancel(reason: String? = nil) {
        cancellation(reason)
    }
}

public extension IndeRunApi {
    /// Makes registered providers ready ahead of a run. Optional, for applications that want the
    /// first call to be fast or want to show progress: without it, the first run of a task waits
    /// for what is loading by itself. A download starts only where `autoDownload` at registration
    /// or `PrepareRequest.allowDownload` permits it. See ADR 019.
    ///
    /// - Parameter onProgress: Called as an item advances, with the provider, the task, and a
    ///   fraction from 0 to 1 when the platform has one.
    func prepare(
        _ request: PrepareRequest = PrepareRequest(),
        onProgress: (@Sendable (String, String, Double?) -> Void)? = nil
    ) async throws -> Preparation {
        let run = try await prepare(request: request)
        let runId = run.handle.runId
        let task = Task<PreparationResult, Error> {
            for try await event in run.events {
                if event.type == "preparation_progress", let payload = event.payload {
                    onProgress?(payload.providerId ?? "", payload.task ?? "", payload.fractionCompleted)
                }
                if event.type == "terminal", let payload = event.payload {
                    if payload.outcome == .error {
                        throw createInternal(message: payload.error?.message ?? "Preparation failed.", runId: runId)
                    }
                    return PreparationResult(
                        cancelled: payload.outcome == .cancelled,
                        items: payload.output?.preparation ?? [],
                        runId: runId
                    )
                }
            }
            throw createInternal(message: "Run \(runId) ended without a terminal event.", runId: runId)
        }
        return Preparation(runId: runId, task: task) { reason in run.cancel(reason: reason) }
    }
}
