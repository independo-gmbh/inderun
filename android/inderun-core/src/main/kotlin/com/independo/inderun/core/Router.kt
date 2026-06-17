package com.independo.inderun.core

import com.independo.inderun.contracts.ExecutionPolicy
import com.independo.inderun.contracts.TaskRequest

data class RouteSelection(
    val provider: ProviderAdapter,
    val explanation: String
)

class Router(
    private val registry: ProviderRegistry
) {
    suspend fun selectRoute(
        request: TaskRequest,
        hostServices: HostServices
    ): RouteSelection {
        val taskKind = request.task.kind.rawValue
        val candidates = registry.list()
            .map { provider -> provider to provider.describe() }
            .sortedBy { (_, descriptor) -> descriptor.id }

        val taskCandidates = candidates.filter { (_, descriptor) ->
            descriptor.tasks.contains(taskKind) && descriptor.supports.run
        }

        return when (request.policy.execution) {
            ExecutionPolicy.ON_DEVICE -> {
                val localCandidates = taskCandidates.filter { (_, descriptor) ->
                    descriptor.type == ProviderDescriptor.ProviderType.local
                }

                if (localCandidates.isEmpty()) {
                    throw createCapabilityMismatch(
                        "Capability mismatch: no on-device provider found supporting task '$taskKind'."
                    )
                }

                for ((provider, descriptor) in localCandidates) {
                    val capabilities = provider.capabilities(hostServices)
                    if (capabilities.available) {
                        return RouteSelection(
                            provider = provider,
                            explanation = "Selected on-device provider '${descriptor.id}' deterministically."
                        )
                    }
                }

                throw createCapabilityMismatch(
                    "Capability mismatch: on-device execution selected, but on-device provider is currently unavailable."
                )
            }

            ExecutionPolicy.CLOUD -> {
                if (!hostServices.connectivity.isOnline()) {
                    throw createOffline(
                        "Offline: cloud execution selected, but no network connection is available."
                    )
                }

                val cloudCandidates = taskCandidates.filter { (_, descriptor) ->
                    descriptor.type == ProviderDescriptor.ProviderType.cloud
                }

                if (cloudCandidates.isEmpty()) {
                    throw createUnavailable(
                        "Unavailable: no cloud provider found supporting task '$taskKind'."
                    )
                }

                for ((provider, descriptor) in cloudCandidates) {
                    val capabilities = provider.capabilities(hostServices)
                    if (capabilities.available) {
                        return RouteSelection(
                            provider = provider,
                            explanation = "Selected cloud provider '${descriptor.id}' deterministically."
                        )
                    }
                }

                throw createUnavailable(
                    "Unavailable: cloud execution selected, but no cloud provider is currently available."
                )
            }
        }
    }
}
