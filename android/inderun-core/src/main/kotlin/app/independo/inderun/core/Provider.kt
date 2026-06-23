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
    val privacy: PrivacyDescriptor? = null
) {
    enum class ProviderType {
        local,
        edge,
        cloud
    }

    enum class TransportType {
        in_process,
        system_service,
        http,
        sse,
        realtime
    }

    enum class StreamingStyle {
        tokens,
        chunks,
        snapshots
    }

    data class SupportsCapabilities(
        val run: Boolean,
        val streaming: Boolean,
        val realtime: Boolean,
        val tools: Boolean,
        val reasoningEvents: Boolean,
        val structuredOutput: Boolean,
        val multimodal: Boolean
    )

    enum class CancelSemantics {
        hard,
        soft,
        none
    }

    data class ResourceLimits(
        val maxInputTokens: Int? = null,
        val maxOutputTokens: Int? = null,
        val maxImageBytes: Int? = null,
        val maxAudioSeconds: Int? = null
    )

    data class PrivacyDescriptor(
        val dataLeavesDevice: Boolean,
        val regions: List<String>? = null
    )
}

data class ProviderDynamicCapabilities(
    val available: Boolean,
    val reason: String? = null
)

data class RunContext(
    val runId: String,
    val hostServices: HostServices
)

interface ProviderAdapter {
    fun describe(): ProviderDescriptor
    suspend fun capabilities(host: HostServices): ProviderDynamicCapabilities
    suspend fun run(request: TaskRequest, context: RunContext): TaskResult
}
