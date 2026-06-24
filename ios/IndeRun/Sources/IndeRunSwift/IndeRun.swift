import Foundation
import IndeRunCore
import IndeRunContracts

public final class IndeRun: Sendable {
    private let registry: ProviderRegistry
    private let hostServices: HostServices
    private let telemetryService: (any TelemetryService)?
    private let router: Router
    
    public init(
        registry: ProviderRegistry,
        hostServices: HostServices,
        telemetryService: (any TelemetryService)? = nil
    ) {
        self.registry = registry
        self.hostServices = hostServices
        self.telemetryService = telemetryService ?? hostServices.telemetry
        self.router = Router(registry: registry)
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
        
        do {
            // 1. Structural request validation
            var validationIssues: [String] = []
            if request.schemaVersion.rawValue != "1.0" {
                validationIssues.append("schemaVersion must be '1.0'")
            }
            if request.task.kind.rawValue != "text_to_text" {
                validationIssues.append("task.kind must be 'text_to_text'")
            }
            
            let hasPrompt = request.prompt != nil && !request.prompt!.isEmpty
            let hasMessages = request.messages != nil && !request.messages!.isEmpty

            if let requestId = request.requestId, requestId.isEmpty {
                validationIssues.append("requestId must be non-empty when provided.")
            }
            if let prompt = request.prompt, prompt.isEmpty {
                validationIssues.append("prompt must be non-empty when provided.")
            }
            if let authContextRef = request.authContextRef, authContextRef.isEmpty {
                validationIssues.append("authContextRef must be non-empty when provided.")
            }
            if let messages = request.messages, messages.contains(where: { $0.content.isEmpty }) {
                validationIssues.append("messages[].content must be non-empty.")
            }
            if !hasPrompt && !hasMessages {
                validationIssues.append("Either prompt or messages must be provided and non-empty.")
            }
            
            if !validationIssues.isEmpty {
                let message = "Validation failed for TaskRequest: " + validationIssues.joined(separator: "; ")
                throw createInternal(
                    message: message,
                    runId: runId,
                    details: ["validationIssues": JSONAny(validationIssues.joined(separator: ", "))]
                )
            }
            
            // 2. Select route
            let routeSelection = try await router.selectRoute(request: request, hostServices: hostServices)
            let providers = [routeSelection.provider] + routeSelection.fallbackProviders
            
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
                    "explanation": JSONAny(routeSelection.explanation)
                ]
            ))
            
            // 3. Execute
            var attemptedIds: [String] = []
            for (index, provider) in providers.enumerated() {
                let providerId = provider.describe().id
                attemptedIds.append(providerId)

                do {
                    var result = try await provider.run(
                        request: request,
                        context: RunContext(runId: runId, hostServices: hostServices)
                    )

                    let endTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
                    let totalMs = Double(endTime - startTime)

                    result.runId = runId
                    result.telemetry.providerUsed = providerId
                    result.telemetry.totalMs = totalMs

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
                    if index == providers.count - 1 {
                        throw toIndeRunException(
                            error,
                            fallbackRunId: runId,
                            fallbackProviderId: providerId,
                            fallbackDetails: [
                                "attemptedProviderIds": JSONAny(attemptedIds),
                                "fallbackOccurred": JSONAny(providers.count > 1),
                                "routePlanSummary": JSONAny(routeSelection.routePlan.explanation.summary)
                            ]
                        )
                    }
                }
            }
            
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let endTime = hostServices.clock?.now() ?? Int64(Date().timeIntervalSince1970 * 1000)
            let totalMs = Double(endTime - startTime)
            
            let exception = toIndeRunException(
                error,
                fallbackRunId: runId,
                fallbackDetails: ["totalMs": JSONAny(totalMs) ]
            )
            
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
}
