package app.independo.inderun.core

import android.content.Context
import androidx.annotation.RequiresPermission
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import app.independo.inderun.contracts.TelemetryEvent
import kotlinx.coroutines.flow.Flow

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
 * A streamed HTTP response: the status line and headers are resolved first, and
 * the body is delivered incrementally as raw byte chunks.
 *
 * The head is deliberately separated from the body so a caller can classify a
 * non-2xx response (mapping it through the normal HTTP error taxonomy) before
 * deciding to interpret the body as a protocol stream. Chunk boundaries are
 * transport artifacts and carry no meaning: a chunk may split a protocol frame
 * or even a multi-byte UTF-8 sequence, so consumers must buffer and decode
 * incrementally rather than treating a chunk as a unit.
 *
 * [body] is cold and single-use: collecting it consumes the underlying
 * connection, and collecting it a second time fails.
 */
data class HttpStreamResponse(
    val status: Long,
    val statusText: String,
    val headers: Map<String, String>,
    val body: Flow<ByteArray>,
)

/**
 * Optional host capability for HTTP responses that must be consumed while they
 * are still arriving — the transport requirement behind Mode 2 streaming over
 * the network (for example server-sent events).
 *
 * It is a separate interface rather than a member of [HttpClientService]
 * because it is genuinely optional: a host that cannot stream simply omits it,
 * and providers report that as `streamingAvailable = false` in their dynamic
 * capabilities, which the route planner turns into an inspectable
 * `streaming_unavailable` rejection.
 */
interface HttpStreamingClientService {
    /**
     * Dispatches a normalized HTTP request and returns once the response head is
     * available, leaving the body to be consumed incrementally.
     *
     * [HttpRequest.timeoutMs] bounds the wait for the response head only — the
     * time to first byte. It cannot bound total duration, since a stream is
     * open-ended by nature; cancel the collecting coroutine to stop a stream
     * that runs too long.
     */
    suspend fun stream(request: HttpRequest): HttpStreamResponse
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
            httpClient = URLConnectionHttpClientService(),
            streamingHttpClient = URLConnectionStreamingHttpClientService(),
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
    /**
     * HTTP client service for responses consumed while still arriving. Absent on
     * hosts that cannot stream a response body.
     */
    val streamingHttpClient: HttpStreamingClientService? = null,
    val telemetry: TelemetryService? = null,
)
