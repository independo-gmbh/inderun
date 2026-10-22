import Foundation
import IndeRunCore
import IndeRunContracts

public final class IndeRun: IndeRunApi {
    private let registry: ProviderRegistry
    private let hostServices: HostServices
    private let telemetryService: (any TelemetryService)?
    private let router: Router
    private let modelProfiles: ModelProfiles
    /// The engine's in-memory media artifact store (ADR 017). Artifacts outlive the run that
    /// produced them and live until disposed or until this instance is released.
    private let artifacts: ArtifactStore

    /// - Parameters:
    ///   - modelProfiles: Named model profiles requests can route within
    ///     (`TaskRequest.modelProfile`). Defaults to none, so every request routes
    ///     within the built-in `auto` profile.
    ///   - artifactLimits: Size limits of the engine's in-memory artifact store (ADR 017).
    ///     Defaults: 16 MiB per artifact, 64 MiB in total, 1 MiB per `readArtifact` call.
    public init(
        registry: ProviderRegistry,
        hostServices: HostServices,
        telemetryService: (any TelemetryService)? = nil,
        modelProfiles: ModelProfiles = .none,
        artifactLimits: ArtifactLimits = ArtifactLimits()
    ) {
        self.registry = registry
        self.hostServices = hostServices
        self.telemetryService = telemetryService ?? hostServices.telemetry
        self.router = Router(registry: registry)
        self.modelProfiles = modelProfiles
        self.artifacts = ArtifactStore(limits: artifactLimits)
    }

    /// Routes through `router` instead of one planning with the shared core, so tests can
    /// inject a plan the shared planner would never produce.
    init(
        registry: ProviderRegistry,
        hostServices: HostServices,
        router: Router,
        modelProfiles: ModelProfiles = .none,
        artifactLimits: ArtifactLimits = ArtifactLimits()
    ) {
        self.registry = registry
        self.hostServices = hostServices
        self.telemetryService = hostServices.telemetry
        self.router = router
        self.modelProfiles = modelProfiles
        self.artifacts = ArtifactStore(limits: artifactLimits)
    }

    /// The planner input for the request's model profile; `nil` means `auto`.
    /// An unknown name never reaches here: `validate(request:)` rejects it first.
    private func plannerModelProfile(for request: TaskRequest) -> ModelProfile? {
        if case .profile(let profile) = modelProfiles.resolve(request.modelProfile) {
            return profile
        }
        return nil
    }

    private func safeEmit(_ event: TelemetryEvent) {
        guard let telemetry = telemetryService else { return }
        // Telemetry failures must never disrupt primary execution flows.
        telemetry.emit(event: event)
    }

    private func getStableMessage(for errorClass: IndeRunErrorClass) -> String {
        switch errorClass {
        case .CapabilityMismatch:
            return "Provider capability mismatch."
        case .Offline:
            return "Device is offline."
        case .AuthError:
            return "Authentication failed."
        case .RateLimited:
            return "Rate limit exceeded."
        case .Timeout:
            return "Execution timed out."
        case .Unavailable:
            return "Provider is unavailable."
        case .Internal:
            return "An internal engine error occurred."
        }
    }

    /// Structural request validation shared by `run` and `stream`; returns one
    /// human-readable issue per violation, empty when the request is well-formed.
    /// The per-kind rules live in the kind's task profile.
    private func validate(request: TaskRequest) -> [String] {
        var validationIssues: [String] = []
        if request.schemaVersion.rawValue != "1.0" {
            validationIssues.append("schemaVersion must be '1.0'")
        }
        if let requestId = request.requestId, requestId.isEmpty {
            validationIssues.append("requestId must be non-empty when provided.")
        }
        if let authContextRef = request.authContextRef, authContextRef.isEmpty {
            validationIssues.append("authContextRef must be non-empty when provided.")
        }
        validationIssues += TaskProfiles.profile(for: request.task.kind).validate(request)
        if case .unknown = modelProfiles.resolve(request.modelProfile) {
            validationIssues.append(
                "modelProfile '\(request.modelProfile ?? "")' is not a configured model profile."
            )
        }

        return validationIssues
    }

    /// Orchestrates the full execution lifecycle of a `TaskRequest`.
    /// 
    /// This method ensures that:
    /// 1. **Validation**: The request payload adheres to schema contracts.
    /// 2. **Routing**: A provider is selected based on request constraints and host capabilities.
    /// 3. **Execution**: The task is executed via the optimal provider adapter.
    /// 4. **Telemetry**: Results are enriched with timing and metadata.
    ///
    /// A provider failure falls back to the next planned provider unless the attempt had
    /// committed (`RunContext.commit()`, for managed playback no later than its first possible
    /// audible effect); a committed attempt's failure is the run's failure. Text providers
    /// never commit, so text fallback is unchanged. An output that does not match the
    /// request's delivery fails the attempt as `Internal` with details code `output_mismatch`,
    /// as does an artifact the attempt did not hand over through `RunContext.artifacts`.
    /// Artifacts an attempt finished and the run does not return are disposed (ADR 017).
    ///
    /// - Parameter request: The standard request payload including prompt, constraints, preferences, and task description.
    /// - Returns: A normalized `TaskResult` containing generated text and execution telemetry.
    public func run(request: TaskRequest) async throws -> TaskResult {
        let startTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)

        let runId = request.requestId ?? "run_\(UUID().uuidString.prefix(8).lowercased())"
        var provenance = ProvenanceRecorder(modelProfile: request.modelProfile)
        // The provider a failed run had committed to, which the failure is attributed to.
        var committedProvider: (any ProviderAdapter)?

        do {
            // 1. Structural request validation
            let validationIssues = validate(request: request)
            if !validationIssues.isEmpty {
                let message = "Validation failed for TaskRequest: " + validationIssues.joined(separator: "; ")
                throw createInternal(
                    message: message,
                    runId: runId,
                    details: ["validationIssues": JSONAny(validationIssues.joined(separator: ", "))]
                )
            }
            try await checkDestination(request: request, runId: runId)

            // 2. Select route
            let routeSelection = try await router.selectRoute(
                request: request,
                hostServices: hostServices,
                modelProfile: plannerModelProfile(for: request)
            )
            let candidates = routeSelection.candidates
            let providers = candidates.map(\.provider)
            provenance.routed(routeSelection.routePlan)
            let delivery = TaskProfiles.profile(for: request.task.kind).delivery(request)

            let routeTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
            safeEmit(TelemetryEvent(
                type: "route_decided",
                runId: runId,
                timestamp: routeTime,
                payload: [
                    "selectedProviderId": JSONAny(routeSelection.routePlan.selectedProviderId ?? JSONNull()),
                    "fallbackProviderIds": JSONAny(routeSelection.routePlan.fallbackProviderIds),
                    "rejectedProviderIds": JSONAny(routeSelection.routePlan.rejectedProviders.map { $0.providerId }),
                    "fallbackAvailable": JSONAny(providers.count > 1),
                    "taskKind": JSONAny(request.task.kind.rawValue),
                    "modelProfile": JSONAny(request.modelProfile ?? ModelProfiles.auto),
                    "explanation": JSONAny(routeSelection.explanation)
                ]
            ))

            // 3. Execute the planned provider chain. An attempt that committed (see
            // RunContext.commit) ends the chain: its failure is the run's failure.
            var attemptedIds: [String] = []
            for (index, candidate) in candidates.enumerated() {
                let provider = candidate.provider
                let providerId = provider.describe().id
                attemptedIds.append(providerId)
                let latch = CommitLatch()
                let commit: @Sendable () -> Bool = { latch.commit(unless: { Task.isCancelled }).granted }
                let attemptArtifacts = artifacts.attempt(commit: commit)
                // Whatever the attempt finished and did not return is discarded on every exit,
                // and a commit() arriving after the attempt ended is refused.
                var keptArtifactId: String?
                defer {
                    _ = latch.close()
                    attemptArtifacts.release(keeping: keptArtifactId)
                }

                do {
                    if let refusal = recheckBoundVoice(request: request, providerId: providerId, voice: candidate.voice) {
                        throw refusal
                    }

                    var result = try await provider.run(
                        request: request,
                        context: RunContext(
                            runId: runId,
                            hostServices: hostServices,
                            voice: candidate.voice,
                            artifacts: attemptArtifacts,
                            commit: commit
                        )
                    )
                    result.output = try normalizeOutput(
                        request: request,
                        delivery: delivery,
                        output: result.output,
                        providerId: providerId,
                        attemptArtifacts: attemptArtifacts
                    )
                    result.output = try await deliverToDestination(
                        request: request, output: result.output, providerId: providerId
                    )
                    keptArtifactId = engineOwnedArtifactId(result.output)

                    let endTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
                    let totalMs = Double(endTime - startTime)

                    result.runId = runId
                    result.telemetry.providerUsed = providerId
                    result.telemetry.totalMs = totalMs
                    provenance.attempted(providerId, .succeeded, committed: latch.isCommitted)
                    result.provenance = provenance.build(
                        attributedTo: provider.describe(),
                        reportedModel: result.telemetry.reportedModel
                    )

                    safeEmit(TelemetryEvent(
                        type: "attempt_succeeded",
                        runId: runId,
                        timestamp: endTime,
                        payload: [
                            "providerId": JSONAny(providerId),
                            "durationMs": JSONAny(totalMs),
                            "fallbackOccurred": JSONAny(index > 0),
                            "attemptedProviderIds": JSONAny(attemptedIds)
                        ]
                    ))

                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Closing first settles the commit state: a provider callback racing this
                    // failure either committed before it or is refused.
                    let committed = latch.close()
                    let attemptError = toIndeRunException(
                        error,
                        fallbackRunId: runId,
                        fallbackProviderId: providerId,
                        fallbackDetails: [
                            "attemptedProviderIds": JSONAny(attemptedIds),
                            "fallbackOccurred": JSONAny(attemptedIds.count > 1),
                            "routePlanSummary": JSONAny(routeSelection.routePlan.explanation.summary)
                        ]
                    )
                    provenance.attempted(
                        providerId, .failed, errorClass: attemptError.errorClass, committed: committed
                    )
                    if committed {
                        committedProvider = provider
                        throw attemptError
                    }
                    if index == providers.count - 1 {
                        throw attemptError
                    }
                }
            }

        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let endTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
            let totalMs = Double(endTime - startTime)

            let normalized = toIndeRunException(
                error,
                fallbackRunId: runId,
                fallbackDetails: ["totalMs": JSONAny(totalMs) ]
            )
            // A routing refusal throws before any attempt; its rejections travel on the
            // details. No attempt produced a result, so the outcome is attributed to no one --
            // unless the run had committed to a provider, which then owns the failure.
            provenance.routingFailed(normalized.details)
            let exception = normalized.withProvenance(provenance.build(attributedTo: committedProvider?.describe()))

            safeEmit(TelemetryEvent(
                type: "attempt_failed",
                runId: runId,
                timestamp: endTime,
                payload: [
                    "providerId": exception.providerId.map(JSONAny.init) ?? JSONAny(JSONNull()),
                    "durationMs": JSONAny(totalMs),
                    "errorClass": JSONAny(exception.errorClass.rawValue),
                    "message": JSONAny(getStableMessage(for: exception.errorClass))
                ]
            ))

            throw exception
        }

        throw createInternal(
            message: "Execution fell through unexpectedly.",
            runId: runId
        )
    }

    /// Orchestrates a Mode 2 (streaming) execution of a `TaskRequest`.
    ///
    /// The requested interaction mode is a routing input, not a filter applied
    /// after routing: the planner rejects providers that cannot stream with their
    /// own normalized reason, so a stream and a run over the same registry may
    /// legitimately resolve to different provider chains.
    ///
    /// Two failure surfaces exist, deliberately. Validation and route-selection
    /// failures reject this call, because there is no handle to correlate them
    /// with yet. Everything after that — provider failure, cancellation,
    /// completion — arrives as the single terminal `StreamEvent` in `events`.
    ///
    /// Fallback is narrower than Mode 1's: a provider failure is only
    /// fallback-eligible before the run commits to that provider -- its first
    /// content event, its explicit `commit()` (managed playback, before the first
    /// possible audible effect), or its result handoff, whichever comes first. Once
    /// committed, a later failure becomes a terminal error, never a silent provider
    /// swap. Cancellation forecloses both at any commit state.
    ///
    /// The run starts as soon as this method returns, rather than on first
    /// iteration of `events`; the handle's `startedAt` says so.
    ///
    /// - Parameter request: The canonical task request.
    /// - Returns: The run handle, its canonical event sequence, and a cancel hook.
    public func stream(request: TaskRequest) async throws -> StreamRun {
        let startTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
        let runId = request.requestId ?? "run_\(UUID().uuidString.prefix(8).lowercased())"

        var provenance = ProvenanceRecorder(modelProfile: request.modelProfile)

        let validationIssues = validate(request: request)
        if !validationIssues.isEmpty {
            throw createInternal(
                message: "Validation failed for TaskRequest: " + validationIssues.joined(separator: "; "),
                runId: runId,
                details: ["validationIssues": JSONAny(validationIssues.joined(separator: ", "))]
            ).withProvenance(provenance.build())
        }
        do {
            try await checkDestination(request: request, runId: runId)
        } catch {
            throw toIndeRunException(error, fallbackRunId: runId).withProvenance(provenance.build())
        }

        let routeSelection: RouteSelection
        do {
            routeSelection = try await router.selectRoute(
                request: request,
                hostServices: hostServices,
                interactionMode: .stream,
                modelProfile: plannerModelProfile(for: request)
            )
        } catch {
            let exception = toIndeRunException(error, fallbackRunId: runId)
            provenance.routingFailed(exception.details)
            throw exception.withProvenance(provenance.build())
        }
        let candidates = routeSelection.candidates
        let providers = candidates.map(\.provider)

        safeEmit(TelemetryEvent(
            type: "route_decided",
            runId: runId,
            timestamp: hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000),
            payload: [
                "selectedProviderId": JSONAny(routeSelection.routePlan.selectedProviderId ?? JSONNull()),
                "fallbackProviderIds": JSONAny(routeSelection.routePlan.fallbackProviderIds),
                "rejectedProviderIds": JSONAny(routeSelection.routePlan.rejectedProviders.map { $0.providerId }),
                "fallbackAvailable": JSONAny(providers.count > 1),
                "taskKind": JSONAny(request.task.kind.rawValue),
                "modelProfile": JSONAny(request.modelProfile ?? ModelProfiles.auto),
                "explanation": JSONAny(routeSelection.explanation)
            ]
        ))

        // Defensive only: streaming eligibility is decided by the route planner,
        // which throws with its own rejection reasons when nothing can stream.
        // Reaching here means a planned provider was unregistered in between.
        guard let first = providers.first else {
            throw createCapabilityMismatch(
                message: "No eligible provider supports streaming for this request.",
                runId: runId,
                details: ["taskKind": JSONAny(request.task.kind.rawValue)]
            )
        }

        let cancellation = StreamCancellationToken()
        let gate = EventGate(runId: runId)
        let handle = StreamRunHandle(
            providerId: first.describe().id,
            runId: runId,
            schemaVersion: .the10,
            startedAt: Double(startTime)
        )

        var continuationBox: AsyncThrowingStream<StreamEvent, Error>.Continuation?
        let events = AsyncThrowingStream<StreamEvent, Error> { continuation in
            continuationBox = continuation
        }
        guard let continuation = continuationBox else {
            throw createInternal(message: "Stream continuation was not initialized.", runId: runId)
        }

        // Retains the engine for the run's lifetime, deliberately. A caller may
        // hold only the returned StreamRun — a stream created from a temporary
        // IndeRun is a reasonable thing to write — and a weak capture there
        // would let the run finish with no terminal event at all, breaking the
        // exactly-one-terminal guarantee. There is no cycle: the engine does not
        // retain this task.
        Task {
            await self.driveStream(
                request: request,
                runId: runId,
                startTime: startTime,
                candidates: candidates,
                routePlan: routeSelection.routePlan,
                gate: gate,
                cancellation: cancellation,
                continuation: continuation
            )
            continuation.finish()
        }

        return StreamRun(handle: handle, events: events) { reason in
            cancellation.cancel(reason: reason)
        }
    }

    // swiftlint:disable:next function_parameter_count cyclomatic_complexity function_body_length
    private func driveStream(
        request: TaskRequest,
        runId: String,
        startTime: Int64,
        candidates: [RouteCandidate],
        routePlan: RoutePlan,
        gate: EventGate,
        cancellation: StreamCancellationToken,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async {
        @Sendable func now() -> Int64 { hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000) }
        func elapsed() -> Double { Double(now() - startTime) }

        var provenance = ProvenanceRecorder(modelProfile: request.modelProfile)
        provenance.routed(routePlan)

        let delivery = TaskProfiles.profile(for: request.task.kind).delivery(request)
        let textRun = delivery == .inline

        /// `provider` is the one running when cancellation landed, if any, and `committed`
        /// whether its attempt had committed; the outcome is attributed to it. A text run
        /// reports what it delivered; committed playback reports that it played; an
        /// uncommitted non-text run produced nothing to report.
        ///
        /// `delivered` is an artifact already written to its application destination: those
        /// bytes are the application's now, so the outcome reports them.
        func emitCancelled(
            partialText: String,
            provider: (any ProviderAdapter)?,
            committed: Bool,
            attempted: [String],
            delivered: TaskOutput? = nil
        ) {
            let providerId = provider?.describe().id
            if let providerId { provenance.attempted(providerId, .cancelled, committed: committed) }
            let outcome = StreamTerminalOutcome.cancelled(
                runId: runId,
                partialText: textRun ? partialText : nil,
                output: delivered ?? (
                    committed && delivery == .playback
                        ? TaskOutput(playback: PlaybackOutput(durationMs: nil))
                        : nil
                ),
                reason: cancellation.reason,
                provenance: provenance.build(attributedTo: provider?.describe())
            )
            let terminal = gate.terminate(outcome: outcome, timestamp: Double(now()))
            var payload: [String: TelemetryValue] = ["attemptedProviderIds": JSONAny(attempted)]
            if let providerId { payload["providerId"] = JSONAny(providerId) }
            safeEmit(TelemetryEvent(
                type: "stream_cancelled", runId: runId, timestamp: now(), payload: payload
            ))
            if let terminal { continuation.yield(terminal) }
        }

        var attemptedProviderIds: [String] = []

        for (index, candidate) in candidates.enumerated() {
            if cancellation.isCancelled { break }

            let provider = candidate.provider
            let providerId = provider.describe().id
            attemptedProviderIds.append(providerId)
            // Set once, by whichever comes first in this attempt: the provider's commit(), its
            // first admitted content event, or its result handoff. After it no other provider
            // is tried. Shared with the provider's context, which may call commit() from its
            // own task, and closed when the attempt ends, so a commit() arriving after the run
            // moved on is refused rather than committing the attempt that replaced this one.
            let latch = CommitLatch()
            safeEmit(TelemetryEvent(
                type: "stream_attempt_started",
                runId: runId,
                timestamp: now(),
                payload: ["providerId": JSONAny(providerId), "fallbackOccurred": JSONAny(index > 0)]
            ))

            guard let streaming = provider as? any StreamingProviderAdapter else {
                // Same class of fault as the empty-chain guard: the planner only
                // routes a stream to providers that conform.
                let exception = createInternal(
                    message: "Provider '\(providerId)' was routed a stream but does not implement streaming.",
                    runId: runId,
                    providerId: providerId
                )
                provenance.attempted(providerId, .failed, errorClass: exception.errorClass)
                if !latch.isCommitted {
                    safeEmit(TelemetryEvent(
                        type: "stream_attempt_failed",
                        runId: runId,
                        timestamp: now(),
                        payload: [
                            "providerId": JSONAny(providerId),
                            "errorClass": JSONAny(exception.errorClass.rawValue),
                            "message": JSONAny(getStableMessage(for: exception.errorClass))
                        ]
                    ))
                    continue
                }
                emitFailure(
                    exception: exception, partialText: textRun ? "" : nil, providerId: providerId,
                    attempted: attemptedProviderIds, runId: runId, gate: gate,
                    continuation: continuation, timestamp: now(),
                    provenance: provenance.build(attributedTo: provider.describe())
                )
                return
            }

            // Emits `stream_attempt_succeeded` exactly once, from whichever commit came first.
            let attemptedSoFar = attemptedProviderIds
            let markCommitted: @Sendable (_ refused: () -> Bool) -> Bool = { refused in
                let (granted, first) = latch.commit(unless: refused)
                if first {
                    self.safeEmit(TelemetryEvent(
                        type: "stream_attempt_succeeded",
                        runId: runId,
                        timestamp: now(),
                        payload: [
                            "providerId": JSONAny(providerId),
                            "attemptedProviderIds": JSONAny(attemptedSoFar)
                        ]
                    ))
                }
                return granted
            }

            let commit: @Sendable () -> Bool = { markCommitted { cancellation.isCancelled || gate.isTerminated } }
            let attemptArtifacts = artifacts.attempt(commit: commit)
            // Whatever the attempt finished and did not return is discarded on every exit; the
            // cancelled and committed-failure paths release earlier, before their terminal.
            var keptArtifactId: String?
            defer {
                _ = latch.close()
                attemptArtifacts.release(keeping: keptArtifactId)
            }

            var partialText = ""
            do {
                if let refusal = recheckBoundVoice(request: request, providerId: providerId, voice: candidate.voice) {
                    throw refusal
                }

                let context = ProviderStreamContext(
                    runId: runId,
                    hostServices: hostServices,
                    cancellation: cancellation,
                    voice: candidate.voice,
                    artifacts: attemptArtifacts,
                    commit: commit
                )

                var terminatedInLoop = false
                providerEvents: for try await event in streaming.stream(request: request, context: context) {
                    if cancellation.isCancelled { break }

                    switch event {
                    case let .failure(error):
                        throw error

                    case let .delta(text), let .snapshot(text):
                        // Content events are text-only (ADR 016 §5).
                        if !textRun, let mismatch = checkOutput(
                            request: request, delivery: delivery, output: TaskOutput(text: ""), providerId: providerId
                        ) {
                            throw mismatch
                        }
                        if case .delta = event {
                            partialText += text
                        } else {
                            partialText = text
                        }
                        _ = markCommitted { false }
                        var type = "content_snapshot"
                        if case .delta = event { type = "content_delta" }
                        if let admitted = gate.admit(
                            timestamp: Double(now()), type: type, payload: .content(text: text)
                        ) {
                            continuation.yield(admitted)
                        }

                    case .done, .result:
                        // The run's final output: text from `.done`, any task's from `.result`.
                        var completion = Self.completion(of: event)
                        completion.output = try normalizeOutput(
                            request: request,
                            delivery: delivery,
                            output: completion.output,
                            providerId: providerId,
                            attemptArtifacts: attemptArtifacts
                        )
                        _ = markCommitted { false }
                        // No destination write starts after a cancel. One already running is
                        // not interrupted, but the run still ends cancelled: bytes already at the
                        // destination are the application's, so the outcome reports them, and
                        // anything the engine still holds is released.
                        if cancellation.isCancelled { break providerEvents }
                        completion.output = try await deliverToDestination(
                            request: request, output: completion.output, providerId: providerId
                        )
                        if cancellation.isCancelled {
                            guard completion.output.artifact?.owner == .application else { break providerEvents }
                            emitCancelled(
                                partialText: partialText,
                                provider: provider,
                                committed: latch.isCommitted,
                                attempted: attemptedProviderIds,
                                delivered: completion.output
                            )
                            return
                        }
                        keptArtifactId = engineOwnedArtifactId(completion.output)
                        provenance.attempted(providerId, .succeeded, committed: true)
                        let outcome = StreamTerminalOutcome.completed(
                            runId: runId,
                            finalText: completion.finalText,
                            output: completion.reportsOutput ? completion.output : nil,
                            finishReason: completion.finishReason,
                            usage: completion.usage,
                            telemetry: StreamTerminalOutcomeTelemetry(
                                providerUsed: providerId,
                                totalMs: elapsed()
                            ),
                            provenance: provenance.build(
                                attributedTo: provider.describe(),
                                reportedModel: completion.reportedModel
                            )
                        )
                        let terminal = gate.terminate(outcome: outcome, timestamp: Double(now()))
                        safeEmit(TelemetryEvent(
                            type: "stream_completed",
                            runId: runId,
                            timestamp: now(),
                            payload: [
                                "providerId": JSONAny(providerId),
                                "durationMs": JSONAny(elapsed()),
                                "attemptedProviderIds": JSONAny(attemptedProviderIds)
                            ]
                        ))
                        terminatedInLoop = true
                        if let terminal { continuation.yield(terminal) }
                    }

                    if terminatedInLoop { return }
                }

                if cancellation.isCancelled {
                    attemptArtifacts.release()
                    emitCancelled(
                        partialText: partialText,
                        provider: provider,
                        committed: latch.isCommitted,
                        attempted: attemptedProviderIds
                    )
                    return
                }

                throw createInternal(
                    message: "Provider '\(providerId)' stream ended without a terminal event.",
                    runId: runId,
                    providerId: providerId
                )
            } catch {
                if cancellation.isCancelled {
                    attemptArtifacts.release()
                    emitCancelled(
                        partialText: partialText,
                        provider: provider,
                        committed: latch.isCommitted,
                        attempted: attemptedProviderIds
                    )
                    return
                }

                // Closing first settles the commit state: a provider callback racing this
                // failure either committed before it or is refused.
                let committed = latch.close()
                let exception = toIndeRunException(
                    error,
                    fallbackRunId: runId,
                    fallbackProviderId: providerId,
                    fallbackDetails: ["attemptedProviderIds": JSONAny(attemptedProviderIds)]
                )
                provenance.attempted(
                    providerId, .failed, errorClass: exception.errorClass, committed: committed
                )

                if !committed {
                    safeEmit(TelemetryEvent(
                        type: "stream_attempt_failed",
                        runId: runId,
                        timestamp: now(),
                        payload: [
                            "providerId": JSONAny(providerId),
                            "errorClass": JSONAny(exception.errorClass.rawValue),
                            "message": JSONAny(getStableMessage(for: exception.errorClass))
                        ]
                    ))
                    continue
                }

                // Committed: the failure belongs to this provider, not to the chain.
                attemptArtifacts.release()
                emitFailure(
                    exception: exception, partialText: textRun ? partialText : nil, providerId: providerId,
                    attempted: attemptedProviderIds, runId: runId, gate: gate,
                    continuation: continuation, timestamp: now(),
                    provenance: provenance.build(attributedTo: provider.describe())
                )
                return
            }
        }

        // Every provider failed pre-commit, or cancellation landed before any
        // attempt started.
        if cancellation.isCancelled {
            emitCancelled(partialText: "", provider: nil, committed: false, attempted: attemptedProviderIds)
            return
        }

        let exception = createUnavailable(
            message: "All eligible streaming providers failed.",
            runId: runId,
            details: ["attemptedProviderIds": JSONAny(attemptedProviderIds)]
        )
        emitFailure(
            exception: exception, partialText: textRun ? "" : nil, providerId: nil,
            attempted: attemptedProviderIds, runId: runId, gate: gate,
            continuation: continuation, timestamp: now(),
            provenance: provenance.build()
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func emitFailure(
        exception: IndeRunException,
        partialText: String?,
        providerId: String?,
        attempted: [String],
        runId: String,
        gate: EventGate,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation,
        timestamp: Int64,
        provenance: ExecutionProvenance
    ) {
        let outcome = StreamTerminalOutcome.failed(
            runId: runId,
            error: exception.toContractError(),
            partialText: partialText,
            provenance: provenance
        )
        let terminal = gate.terminate(outcome: outcome, timestamp: Double(timestamp))
        var payload: [String: TelemetryValue] = [
            "errorClass": JSONAny(exception.errorClass.rawValue),
            "message": JSONAny(getStableMessage(for: exception.errorClass)),
            "attemptedProviderIds": JSONAny(attempted)
        ]
        if let providerId { payload["providerId"] = JSONAny(providerId) }
        safeEmit(TelemetryEvent(type: "stream_failed", runId: runId, timestamp: timestamp, payload: payload))
        if let terminal { continuation.yield(terminal) }
    }

    /// What a terminal `.done` or `.result` event completes the run with. `reportsOutput`
    /// is false for `.done`, whose outcome keeps carrying only `finalText` as it always has.
    private struct Completion {
        var output: TaskOutput
        let finalText: String?
        let reportsOutput: Bool
        let finishReason: FinishReason?
        let usage: TaskResultUsage?
        let reportedModel: String?
    }

    private static func completion(of event: ProviderStreamEvent) -> Completion {
        switch event {
        case let .done(finalText, finishReason, usage, reportedModel):
            return Completion(
                output: TaskOutput(text: finalText), finalText: finalText, reportsOutput: false,
                finishReason: finishReason, usage: usage, reportedModel: reportedModel
            )
        case let .result(output, finishReason, reportedModel):
            return Completion(
                output: output, finalText: output.type == .text ? output.text : nil, reportsOutput: true,
                finishReason: finishReason, usage: nil, reportedModel: reportedModel
            )
        case .delta, .snapshot, .failure:
            preconditionFailure("completion(of:) is only called for .done and .result")
        }
    }

    /// Checks that an artifact in a provider's output is one this attempt produced, swaps in the
    /// reference the store holds, and only then checks the output against the requested
    /// delivery: the artifact's media type, size and ownership are the engine's record rather
    /// than the provider's claim.
    private func normalizeOutput(
        request: TaskRequest,
        delivery: OutputDelivery,
        output: TaskOutput,
        providerId: String,
        attemptArtifacts: AttemptArtifacts
    ) throws -> TaskOutput {
        var resolved = output
        if let artifact = output.artifact {
            guard attemptArtifacts.owns(artifactId: artifact.id),
                  let reference = artifacts.reference(artifactId: artifact.id) else {
                throw createInternal(
                    message: "Provider '\(providerId)' returned an artifact it did not hand over in this attempt.",
                    providerId: providerId,
                    details: ["code": JSONAny("output_mismatch")]
                )
            }
            resolved.artifact = reference
        }
        if let mismatch = checkOutput(request: request, delivery: delivery, output: resolved, providerId: providerId) {
            throw mismatch
        }
        return resolved
    }

    /// Refuses, before routing, an artifact request whose `destinationRef` this host cannot
    /// write to: there is no point running a provider whose result has nowhere to go.
    private func checkDestination(request: TaskRequest, runId: String) async throws {
        guard let destinationRef = request.delivery?.destinationRef else { return }
        guard let destinations = hostServices.artifactDestinations else {
            throw createCapabilityMismatch(
                message: "This host has no application artifact destinations.",
                runId: runId,
                details: ["code": JSONAny("artifact_destination_unsupported")]
            )
        }
        if !(await destinations.accepts(destinationRef: destinationRef, mediaTypes: request.delivery?.mediaTypes)) {
            throw createCapabilityMismatch(
                message: "The host refused the requested artifact destination.",
                runId: runId,
                details: ["code": JSONAny("artifact_destination_refused")]
            )
        }
    }

    /// Writes a finished artifact to the request's application destination, if it names one,
    /// and drops the engine's copy: the result's artifact is then application-owned. The run
    /// has committed by now, so a failed write is the run's failure, never a fallback.
    private func deliverToDestination(
        request: TaskRequest,
        output: TaskOutput,
        providerId: String
    ) async throws -> TaskOutput {
        guard let destinationRef = request.delivery?.destinationRef,
              let artifact = output.artifact else { return output }
        // Both hold here: `checkDestination` refused the request otherwise, and
        // `normalizeOutput` only returns an artifact the store still holds.
        guard let destinations = hostServices.artifactDestinations,
              let bytes = artifacts.bytes(artifactId: artifact.id) else {
            throw createInternal(
                message: "The artifact to write to its application destination is no longer held.",
                providerId: providerId,
                details: ["code": JSONAny("artifact_destination_write_failed")]
            )
        }
        do {
            try await destinations.write(destinationRef: destinationRef, artifact: artifact, bytes: bytes)
        } catch {
            // The host's error stays out of the run's error: it may name the destination.
            artifacts.dispose(artifactId: artifact.id)
            throw createInternal(
                message: "Writing the artifact to its application destination failed.",
                providerId: providerId,
                details: ["code": JSONAny("artifact_destination_write_failed")]
            )
        }
        artifacts.dispose(artifactId: artifact.id)
        var delivered = output
        delivered.artifact?.owner = .application
        delivered.artifact?.destinationRef = destinationRef
        return delivered
    }

    /// Reads a byte range of an engine-owned media artifact (ADR 017). See
    /// `IndeRunApi.readArtifact`.
    public func readArtifact(request: ArtifactReadRequest) async throws -> ArtifactChunk {
        var issues: [(path: String, message: String)] = []
        if request.artifactId.isEmpty {
            issues.append((path: "/artifactId", message: "artifactId must be non-empty."))
        }
        if let offset = request.offset, offset < 0 {
            issues.append((path: "/offset", message: "offset must be >= 0."))
        }
        if let maxBytes = request.maxBytes, maxBytes < 1 {
            issues.append((path: "/maxBytes", message: "maxBytes must be >= 1."))
        }
        if !issues.isEmpty {
            throw artifactReadValidationFailure(issues)
        }
        return try artifacts.read(request)
    }

    /// Releases an engine-owned artifact's bytes. Idempotent; an application-owned artifact
    /// holds nothing in the engine, so disposing one does nothing.
    public func disposeArtifact(artifact: MediaArtifact) async {
        if artifact.owner == .engine {
            artifacts.dispose(artifactId: artifact.id)
        }
    }

    /// Reports each registered provider's static descriptor and current dynamic capability check,
    /// without executing a task. Useful for UI that shows live provider availability before a run.
    public func checkCapabilities() async -> [ProviderCapabilitySnapshot] {
        var snapshots: [ProviderCapabilitySnapshot] = []
        for provider in registry.list() {
            let descriptor = provider.describe()
            let capabilities = await provider.capabilities(host: hostServices)
            snapshots.append(
                ProviderCapabilitySnapshot(
                    providerId: descriptor.id,
                    descriptor: descriptor,
                    capabilities: capabilities
                )
            )
        }
        return snapshots
    }
}

/// The id of an artifact output the engine still holds, which an attempt must keep.
private func engineOwnedArtifactId(_ output: TaskOutput) -> String? {
    output.artifact?.owner == .engine ? output.artifact?.id : nil
}

/// Records the moment a run committed to one attempt's provider (see `RunContext.commit()`).
/// Locked, because a provider may call `commit()` from a task of its own while the engine
/// reads the state from the task driving the run.
private final class CommitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = false
    private var closed = false

    var isCommitted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    /// Commits unless `refused()` says the run can no longer commit. `granted` is what
    /// `commit()` returns to the provider; `first` is true only for the call that committed.
    func commit(unless refused: () -> Bool) -> (granted: Bool, first: Bool) {
        if refused() { return (false, false) }
        lock.lock()
        defer { lock.unlock() }
        if closed { return (false, false) }
        if committed { return (true, false) }
        committed = true
        return (true, true)
    }

    /// Ends the attempt: every later `commit()` is refused. Returns whether the attempt had
    /// committed, read under the same lock, so no commit can land between the two.
    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return committed
    }
}
