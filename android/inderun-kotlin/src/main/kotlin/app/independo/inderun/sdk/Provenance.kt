package app.independo.inderun.sdk

import app.independo.inderun.contracts.AttemptOutcome
import app.independo.inderun.contracts.Code
import app.independo.inderun.contracts.ExecutionProvenance
import app.independo.inderun.contracts.ExecutionProvenanceAttempt
import app.independo.inderun.contracts.ExecutionProvenanceRouteRejection
import app.independo.inderun.contracts.IndeRunErrorClass
import app.independo.inderun.contracts.Locality
import app.independo.inderun.contracts.ProviderDescriptor
import app.independo.inderun.contracts.ProviderType
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.core.ModelProfiles

/**
 * Accumulates what one execution did -- each attempt and how it ended -- and renders it as the
 * normalized [ExecutionProvenance] carried on results, terminal outcomes, and errors. Mirrors
 * `ProvenanceRecorder` in the Web SDK's engine.
 *
 * Everything recorded is either observed by the engine (attempts, their outcomes) or declared or
 * reported by a provider (descriptor type and model, the model a response names). Nothing is
 * inferred: an unknown is left null or reported as [Locality.Unknown].
 *
 * Not thread-safe: one recorder belongs to one run, and a run's attempts are sequential.
 */
internal class ProvenanceRecorder(modelProfile: String?) {
    private val modelProfile = modelProfile ?: ModelProfiles.AUTO
    private val attempts = mutableListOf<ExecutionProvenanceAttempt>()
    private var routeRejections = emptyList<ExecutionProvenanceRouteRejection>()

    /** Records the planner's rejections; codes only, never the provider-supplied messages. */
    fun routed(routePlan: RoutePlan) {
        routeRejections = routePlan.rejectedProviders.map { rejected ->
            ExecutionProvenanceRouteRejection(
                codes = rejected.reasons.map { it.code },
                providerId = rejected.providerId,
            )
        }
    }

    /**
     * Records the rejections a routing failure carried out on its exception's details, which the
     * router flattens to plain maps.
     */
    fun routingFailed(details: Map<String, Any?>?) {
        val rejected = details?.get("rejectedProviders") as? List<*> ?: return
        routeRejections = rejected.mapNotNull { entry ->
            val provider = entry as? Map<*, *> ?: return@mapNotNull null
            val providerId = provider["providerId"] as? String ?: return@mapNotNull null
            val reasons = provider["reasons"] as? List<*> ?: emptyList<Any?>()
            ExecutionProvenanceRouteRejection(
                codes = reasons.mapNotNull { reason ->
                    ((reason as? Map<*, *>)?.get("code") as? String)?.let(Code::fromRawValue)
                },
                providerId = providerId,
            )
        }
    }

    /** Records how one provider attempt ended. */
    fun attempted(providerId: String, outcome: AttemptOutcome, errorClass: IndeRunErrorClass? = null) {
        attempts += ExecutionProvenanceAttempt(errorClass = errorClass, outcome = outcome, providerId = providerId)
    }

    /**
     * Renders the record. [attributedTo] is the provider the outcome belongs to -- the one that
     * produced the result, the one a stream was committed to, or the one running at cancellation --
     * and is null when no provider was reached or every attempt failed before a commit.
     */
    fun build(attributedTo: ProviderDescriptor? = null, reportedModel: String? = null): ExecutionProvenance = ExecutionProvenance(
        attemptCount = attempts.size.toLong(),
        attempts = attempts.toList(),
        configuredModel = attributedTo?.model,
        fallbackOccurred = attempts.size > 1,
        locality = attributedTo?.let(::localityOf) ?: Locality.Unknown,
        modelProfile = modelProfile,
        providerId = attributedTo?.id,
        reportedModel = if (attributedTo == null) null else reportedModel,
        routeRejections = routeRejections,
    )

    private fun localityOf(descriptor: ProviderDescriptor): Locality = when (descriptor.type) {
        ProviderType.Local -> Locality.OnDevice
        ProviderType.Edge -> Locality.Edge
        ProviderType.Cloud -> Locality.Cloud
    }
}
