package com.independo.inderun.core

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class ProviderRegistry {
    private val lock = ReentrantLock()
    private val providers = linkedMapOf<String, ProviderAdapter>()

    fun register(provider: ProviderAdapter) {
        lock.withLock {
            val descriptor = provider.describe()
            require(descriptor.id.isNotBlank()) { "Provider must have a non-empty ID." }
            check(!providers.containsKey(descriptor.id)) {
                "Provider with ID \"${descriptor.id}\" is already registered."
            }
            providers[descriptor.id] = provider
        }
    }

    fun get(id: String): ProviderAdapter? = lock.withLock {
        providers[id]
    }

    fun list(): List<ProviderAdapter> = lock.withLock {
        providers.values.toList()
    }

    fun clear() {
        lock.withLock {
            providers.clear()
        }
    }
}
