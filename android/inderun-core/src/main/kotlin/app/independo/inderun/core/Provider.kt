package app.independo.inderun.core

import app.independo.inderun.contracts.TaskRequest
import app.independo.inderun.contracts.TaskResult

data class ProviderDescriptor(
    val id: String,
    val type: ProviderType,
    val transport: TransportType,
    val streamingStyle: StreamingStyle? = null,
    val supports: SupportsCapabilities,
    val cancel: CancelSemantics,
    val tasks: List<String>,
    val limits: ResourceLimits? = null,
    val privacy: PrivacyDescriptor? = null,
) {
    enum class ProviderType {
        local,
        edge,
        cloud,
    }

    enum class TransportType {
        in_process,
        system_service,
        http,
        sse,
        realtime,
    }

    enum class StreamingStyle {
        tokens,
        chunks,
        snapshots,
    }

    data class SupportsCapabilities(
        val run: Boolean,
        val streaming: Boolean,
        val realtime: Boolean,
        val tools: Boolean,
        val reasoningEvents: Boolean,
        val structuredOutput: Boolean,
        val multimodal: Boolean,
    )

    enum class CancelSemantics {
        hard,
        soft,
        none,
    }

    data class ResourceLimits(
        val maxInputTokens: Int? = null,
        val maxOutputTokens: Int? = null,
        val maxImageBytes: Int? = null,
        val maxAudioSeconds: Int? = null,
    )

    data class PrivacyDescriptor(
        val dataLeavesDevice: Boolean,
        val regions: List<String>? = null,
    )
}

data class ProviderDynamicCapabilities(
    val available: Boolean,
    val reason: String? = null,
    /**
     * Whether the provider can stream (Mode 2) right now on this host. Leave null
     * to inherit the static `descriptor.supports.streaming` value — only set it
     * when the runtime environment can take streaming away from a provider that
     * otherwise declares it.
     */
    val streamingAvailable: Boolean? = null,
    /**
     * Detail message used when [streamingAvailable] is false. Leave null to let
     * the route planner synthesize a generic message.
     */
    val streamingUnavailableReason: String? = null,
    /**
     * Whether cancellation is honored right now on this host. Leave null to
     * inherit the static `descriptor.cancel` value (anything other than `none`
     * means available).
     */
    val cancellationAvailable: Boolean? = null,
)

/**
 * One registered provider's identity, fixed capabilities, and live availability,
 * as of the moment checkCapabilities() was called.
 */
data class ProviderCapabilitySnapshot(
    /**
     * Stable identifier for this provider, matching the value used in routing
     * preferences/constraints.
     */
    val providerId: String,
    /**
     * The provider's static, unchanging capability declaration (supported modes,
     * privacy posture, model info).
     */
    val descriptor: ProviderDescriptor,
    /**
     * The provider's current dynamic availability (e.g. whether it's reachable/loaded
     * right now) — this is the part that can change between calls.
     */
    val capabilities: ProviderDynamicCapabilities,
)

data class RunContext(
    val runId: String,
    val hostServices: HostServices,
)

interface ProviderAdapter {
    fun describe(): ProviderDescriptor
    suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities
    suspend fun run(request: TaskRequest, context: RunContext): TaskResult
}
