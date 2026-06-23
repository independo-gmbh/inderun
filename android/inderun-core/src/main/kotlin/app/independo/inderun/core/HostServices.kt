package app.independo.inderun.core

import android.content.Context
import androidx.annotation.RequiresPermission
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import app.independo.inderun.contracts.TelemetryEvent

/**
 * Service responsible for monitoring network connectivity status.
 */
interface ConnectivityService {
    /**
     * Returns true if the device has active internet connectivity.
     */
    @RequiresPermission(android.Manifest.permission.ACCESS_NETWORK_STATE)
    fun isOnline(): Boolean
}

/**
 * Service providing access to secure storage for credentials and secrets.
 */
interface SecureStorageService {
    /**
     * Retrieves a value associated with the given [authContextRef].
     *
     * @param authContextRef The unique identifier/slot name for the credential.
     * @return The retrieved secret string, or null if not found.
     */
    fun get(authContextRef: String): String?

    /**
     * Stores a value in the slot identified by [authContextRef].
     */
    fun put(authContextRef: String, value: String)

    /**
     * Removes the slot identified by [authContextRef].
     */
    fun remove(authContextRef: String)
}

/**
 * Service providing access to a monotonic clock.
 */
interface ClockService {
    /**
     * Returns monotonic elapsed time in milliseconds since boot.
     */
    fun elapsedRealtimeMillis(): Long
}

/**
 * Service responsible for dispatching normalized HTTP transport requests.
 */
interface HttpClientService {
    suspend fun send(request: HttpRequest): HttpResponse
}

/**
 * Optional telemetry sink for normalized engine and provider events.
 */
interface TelemetryService {
    fun emit(event: TelemetryEvent)
}

/**
 * A factory for creating the default implementation of [HostServices].
 */
object HostServicesFactory {
    /**
     * Creates a new instance of [HostServices] using the provided Android [Context].
     *
     * @param context The application or activity context.
     * @return An initialized [HostServices] container.
     */
    fun create(context: Context): HostServices {
        val appContext = context.applicationContext
        return HostServices(
            connectivity = ConnectivityServiceImpl(appContext),
            secureStorage = SecureStorageServiceImpl(appContext),
            clock = ClockServiceImpl(),
            httpClient = URLConnectionHttpClientService()
        )
    }
}

/**
 * Container for all required [HostServices] in the IndeRun framework.
 */
data class HostServices(
    val connectivity: ConnectivityService,
    val secureStorage: SecureStorageService,
    val clock: ClockService,
    val httpClient: HttpClientService? = null,
    val telemetry: TelemetryService? = null
)
