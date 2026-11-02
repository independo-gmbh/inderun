package app.independo.inderun.core

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * How a provider takes part in preparation (ADR 019).
 *
 * @property autoDownload Lets `prepare`, explicit or on the first run, start this provider's
 *   platform download. Off by default: a download can use mobile data, so it is the application's
 *   decision. Off, a call can still allow one with `PrepareRequest.allowDownload`.
 */
data class ProviderRegistrationOptions(val autoDownload: Boolean = false)

class ProviderRegistry {
    private val lock = ReentrantLock()
    private val providers = linkedMapOf<String, ProviderAdapter>()
    private val options = mutableMapOf<String, ProviderRegistrationOptions>()

    fun register(provider: ProviderAdapter, options: ProviderRegistrationOptions = ProviderRegistrationOptions()) {
        lock.withLock {
            val descriptor = provider.describe()
            require(descriptor.id.isNotBlank()) { "Provider must have a non-empty ID." }
            check(!providers.containsKey(descriptor.id)) {
                "Provider with ID \"${descriptor.id}\" is already registered."
            }
            providers[descriptor.id] = provider
            this.options[descriptor.id] = options
        }
    }

    /** Whether `prepare` may start this provider's platform download on its own. */
    fun allowsAutoDownload(id: String): Boolean = lock.withLock { options[id]?.autoDownload == true }

    fun get(id: String): ProviderAdapter? = lock.withLock {
        providers[id]
    }

    fun list(): List<ProviderAdapter> = lock.withLock {
        providers.values.toList()
    }

    fun clear() {
        lock.withLock {
            providers.clear()
            options.clear()
        }
    }
}
