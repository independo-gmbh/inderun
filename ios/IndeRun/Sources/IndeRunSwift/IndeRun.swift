import Foundation
import IndeRunCore
import IndeRunContracts

public final class IndeRun: IndeRunApi {
    private let registry: ProviderRegistry
    private let hostServices: HostServices
    private let telemetryService: (any TelemetryService)?
    private let router: Router
    private let modelProfiles: ModelProfiles

    /// - Parameter modelProfiles: Named model profiles requests can route within
    ///   (`TaskRequest.modelProfile`). Defaults to none, so every request routes
    ///   within the built-in `auto` profile.
    public init(
        registry: ProviderRegistry,
        hostServices: HostServices,
        telemetryService: (any TelemetryService)? = nil,
        modelProfiles: ModelProfiles = .none
    ) {
        self.registry = registry
        self.hostServices = hostServices
        self.telemetryService = telemetryService ?? hostServices.telemetry
        self.router = Router(registry: registry)
        self.modelProfiles = modelProfiles
    }

    /// Routes through `router` instead of one planning with the shared core, so tests can
    /// inject a plan the shared planner would never produce.
    init(
        registry: ProviderRegistry,
        hostServices: HostServices,
        router: Router,
        modelProfiles: ModelProfiles = .none
    ) {
        self.registry = registry
        self.hostServices = hostServices
        self.telemetryService = hostServices.telemetry
        self.router = router
        self.modelProfiles = modelProfiles
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
    /// - Parameter request: The standard request payload including prompt, constraints, preferences, and task description.
    /// - Returns: A normalized `TaskResult` containing generated text and execution telemetry.
    public func run(request: TaskRequest) async throws -> TaskResult {
        let startTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)

        let runId = request.requestId ?? "run_\(UUID().uuidString.prefix(8).lowercased())"
        var provenance = ProvenanceRecorder(modelProfile: request.modelProfile)

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

            // 2. Select route
            let routeSelection = try await router.selectRoute(
                request: request,
                hostServices: hostServices,
                modelProfile: plannerModelProfile(for: request)
            )
            let candidates = routeSelection.candidates
            let providers = candidates.map(\.provider)
            provenance.routed(routeSelection.routePlan)

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

            // 3. Execute
            var attemptedIds: [String] = []
            for (index, candidate) in candidates.enumerated() {
                let provider = candidate.provider
                let providerId = provider.describe().id
                attemptedIds.append(providerId)

                do {
                    if let refusal = recheckBoundVoice(request: request, providerId: providerId, voice: candidate.voice) {
                        throw refusal
                    }

                    var result = try await provider.run(
                        request: request,
                        context: RunContext(runId: runId, hostServices: hostServices, voice: candidate.voice)
                    )

                    let endTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
                    let totalMs = Double(endTime - startTime)

                    result.runId = runId
                    result.telemetry.providerUsed = providerId
                    result.telemetry.totalMs = totalMs
                    provenance.attempted(providerId, .succeeded)
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
                    provenance.attempted(providerId, .failed, errorClass: attemptError.errorClass)
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
            // details. No attempt produced a result, so the outcome is attributed to no one.
            provenance.routingFailed(normalized.details)
            let exception = normalized.withProvenance(provenance.build())

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
    /// fallback-eligible before the first content event has been delivered. Once
    /// one has, the run is committed to that provider and a later failure becomes
    /// a terminal error, never a silent provider swap. Cancellation forecloses
    /// both at any commit state.
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
        func now() -> Int64 { hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000) }
        func elapsed() -> Double { Double(now() - startTime) }

        var provenance = ProvenanceRecorder(modelProfile: request.modelProfile)
        provenance.routed(routePlan)

        /// `provider` is the one running when cancellation landed, if any; the outcome
        /// is attributed to it.
        func emitCancelled(partialText: String, provider: (any ProviderAdapter)?, attempted: [String]) {
            let providerId = provider?.describe().id
            if let providerId { provenance.attempted(providerId, .cancelled) }
            let outcome = StreamTerminalOutcome.cancelled(
                runId: runId,
                partialText: partialText,
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
        var committed = false

        for (index, candidate) in candidates.enumerated() {
            if cancellation.isCancelled { break }

            let provider = candidate.provider
            let providerId = provider.describe().id
            attemptedProviderIds.append(providerId)
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
                emitFailure(
                    exception: exception, partialText: "", providerId: providerId,
                    attempted: attemptedProviderIds, runId: runId, gate: gate,
                    continuation: continuation, timestamp: now(),
                    provenance: provenance.build(attributedTo: provider.describe())
                )
                return
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
                    voice: candidate.voice
                )

                var terminatedInLoop = false
                for try await event in streaming.stream(request: request, context: context) {
                    if cancellation.isCancelled { break }

                    switch event {
                    case let .failure(error):
                        throw error

                    case let .delta(text), let .snapshot(text):
                        if case .delta = event {
                            partialText += text
                        } else {
                            partialText = text
                        }
                        if !committed {
                            committed = true
                            safeEmit(TelemetryEvent(
                                type: "stream_attempt_succeeded",
                                runId: runId,
                                timestamp: now(),
                                payload: [
                                    "providerId": JSONAny(providerId),
                                    "attemptedProviderIds": JSONAny(attemptedProviderIds)
                                ]
                            ))
                        }
                        var type = "content_snapshot"
                        if case .delta = event { type = "content_delta" }
                        if let admitted = gate.admit(
                            timestamp: Double(now()), type: type, payload: .content(text: text)
                        ) {
                            continuation.yield(admitted)
                        }

                    case let .done(finalText, finishReason, usage, reportedModel):
                        provenance.attempted(providerId, .succeeded)
                        let outcome = StreamTerminalOutcome.completed(
                            runId: runId,
                            finalText: finalText,
                            finishReason: finishReason,
                            usage: usage,
                            telemetry: StreamTerminalOutcomeTelemetry(
                                providerUsed: providerId,
                                totalMs: elapsed()
                            ),
                            provenance: provenance.build(
                                attributedTo: provider.describe(),
                                reportedModel: reportedModel
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
                    emitCancelled(
                        partialText: partialText,
                        provider: provider,
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
                    emitCancelled(
                        partialText: partialText,
                        provider: provider,
                        attempted: attemptedProviderIds
                    )
                    return
                }

                let exception = toIndeRunException(
                    error,
                    fallbackRunId: runId,
                    fallbackProviderId: providerId,
                    fallbackDetails: ["attemptedProviderIds": JSONAny(attemptedProviderIds)]
                )
                provenance.attempted(providerId, .failed, errorClass: exception.errorClass)

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
                emitFailure(
                    exception: exception, partialText: partialText, providerId: providerId,
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
            emitCancelled(partialText: "", provider: nil, attempted: attemptedProviderIds)
            return
        }

        let exception = createUnavailable(
            message: "All eligible streaming providers failed.",
            runId: runId,
            details: ["attemptedProviderIds": JSONAny(attemptedProviderIds)]
        )
        emitFailure(
            exception: exception, partialText: "", providerId: nil,
            attempted: attemptedProviderIds, runId: runId, gate: gate,
            continuation: continuation, timestamp: now(),
            provenance: provenance.build()
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func emitFailure(
        exception: IndeRunException,
        partialText: String,
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
