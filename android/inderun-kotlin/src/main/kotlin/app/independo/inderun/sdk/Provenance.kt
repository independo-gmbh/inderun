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
import app.independo.inderun.contracts.ProviderVoice
import app.independo.inderun.contracts.RoutePlan
import app.independo.inderun.contracts.TaskKind
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
    private val boundVoices = mutableMapOf<String, Pair<String, ProviderVoice?>>()

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

    /** Records the voice a provider was handed, which decides what its locality can claim. */
    fun voiceBound(providerId: String, taskKind: String, voice: ProviderVoice?) {
        boundVoices[providerId] = taskKind to voice
    }

    /**
     * Records how one provider attempt ended, and whether the run had committed to it (first
     * content delivered, first possible audible effect, or an artifact handed over).
     */
    fun attempted(
        providerId: String,
        outcome: AttemptOutcome,
        errorClass: IndeRunErrorClass? = null,
        committed: Boolean = false,
    ) {
        attempts += ExecutionProvenanceAttempt(
            committed = if (committed) true else null,
            errorClass = errorClass,
            outcome = outcome,
            providerId = providerId,
        )
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
        locality = attributedTo?.let { localityOf(it, boundVoices[it.id]) } ?: Locality.Unknown,
        modelProfile = modelProfile,
        providerId = attributedTo?.id,
        reportedModel = if (attributedTo == null) null else reportedModel,
        routeRejections = routeRejections,
    )
}

/**
 * The locality to report for a provider. A local provider is on-device only as far as its voice
 * allows: one that may send text off the device reports [Locality.Unknown], because the provider
 * runs here while the synthesis may not. An absent `networkRequired` inherits the task's privacy
 * posture, as it does in the planner. A speech run with no bound voice also reports unknown: an
 * engine that lists no voices chooses one itself, and nothing shows where that one runs.
 */
internal fun localityOf(descriptor: ProviderDescriptor, bound: Pair<String, ProviderVoice?>? = null): Locality = when (descriptor.type) {
    ProviderType.Local -> {
        val mayLeaveDevice = bound?.let { (taskKind, voice) ->
            val task = descriptor.taskCapabilities?.firstOrNull { it.kind == taskKind }
            if (voice == null) {
                taskKind == TaskKind.TEXT_TO_SPEECH.rawValue
            } else {
                voice.networkRequired ?: (task?.privacy ?: descriptor.privacy)?.dataLeavesDevice ?: false
            }
        } ?: false
        if (mayLeaveDevice) Locality.Unknown else Locality.OnDevice
    }
    ProviderType.Edge -> Locality.Edge
    ProviderType.Cloud -> Locality.Cloud
}
