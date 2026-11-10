package app.independo.inderun.core

import android.content.Context
import androidx.annotation.RequiresPermission
import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import app.independo.inderun.contracts.MediaArtifact
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
 * Resolves the opaque `delivery.destinationRef` of an artifact request to a place the application
 * chose -- a file it will hand to a player, a cache it manages -- and writes the finished artifact
 * there (ADR 017). A request names a reference, never a path, so a request that came from a webview
 * cannot address arbitrary storage.
 */
interface ArtifactDestinationService {
    /**
     * Whether [destinationRef] names a destination this host can write the requested media to.
     * Called before routing; `false` refuses the request.
     */
    suspend fun accepts(destinationRef: String, mediaTypes: List<String>?): Boolean

    /**
     * Writes the finished artifact's [bytes] to the destination. A failure fails the run: it is
     * committed by then, so it never falls back.
     */
    suspend fun write(destinationRef: String, artifact: MediaArtifact, bytes: ByteArray)
}

/**
 * The sample encoding of an [AudioOutputFormat]. Always signed 16-bit little-endian PCM.
 */
enum class AudioOutputEncoding(val rawValue: String) {
    PcmS16le("pcm_s16le"),
}

/**
 * The PCM format of one audio output session. Every host accepts mono signed 16-bit
 * little-endian samples at 8000 to 48000 Hz inclusive; a service may refuse further rates
 * with the same `audio_format_unsupported` code (`CapabilityMismatch`).
 *
 * @property sampleRate Samples per second, 8000 to 48000 inclusive.
 * @property channels Always mono.
 * @property encoding Always signed 16-bit little-endian PCM.
 */
data class AudioOutputFormat(
    val sampleRate: Int,
    val channels: Int = 1,
    val encoding: AudioOutputEncoding = AudioOutputEncoding.PcmS16le,
)

/**
 * One playback session. Sessions of one service are independent: stopping one does not
 * disturb another.
 *
 * The normal path is [write] for each chunk, then [drain], then [stop].
 *
 * [write] and [drain] are `suspend` functions that honour coroutine cancellation
 * (`CancellationException`); a provider's cancel path is [stop].
 *
 * A session ends once: by [stop], or by the system taking the output away (an interruption,
 * the output stopping), which ends it with `Unavailable` and `details.code`
 * `audio_output_interrupted`.
 */
interface AudioOutputSession {
    /**
     * Hands samples to the host. Returns once the host has buffered them, so a caller that
     * awaits each write is paced by the output (backpressure). The first write is the first
     * possible audible effect. After [stop], returns at once without effect; after the
     * system ended the session, throws its error.
     */
    suspend fun write(samples: ShortArray)

    /**
     * Returns when everything written has played. After [stop], returns at once without
     * effect; after the system ended the session, throws its error.
     */
    suspend fun drain()

    /**
     * Ends the session now: discards buffered audio and releases the output. Idempotent, and
     * nothing renders after it.
     */
    fun stop()

    /**
     * Milliseconds from the start of [AudioOutputService.open] (the instant it was called, before
     * the output is built or started) to the first frame the host observed leaving the output;
     * `null` until then. A provider reports `firstAudioMs` = (instant before `open()` was called −
     * `receivedAt`) + `session.firstAudioMs()`, so a slow open is counted once.
     */
    fun firstAudioMs(): Double?
}

/**
 * Plays PCM for providers that synthesize audio themselves.
 */
interface AudioOutputService {
    /**
     * Opens a playback session. Makes no sound, and validates the format: one outside the
     * rule on [AudioOutputFormat] throws `CapabilityMismatch` with
     * `details.code` `audio_format_unsupported`. `open` is a `suspend` function that honours
     * coroutine cancellation (`CancellationException`).
     */
    suspend fun open(format: AudioOutputFormat): AudioOutputSession
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
            audioOutput = AudioTrackAudioOutputService(),
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
    /**
     * Application destinations for artifact requests that carry `delivery.destinationRef`.
     * Absent means the host has none, and such a request is refused before routing.
     */
    val artifactDestinations: ArtifactDestinationService? = null,
    /**
     * PCM playback for providers that synthesize audio themselves. Absent on hosts that
     * cannot play audio; such a provider refuses before commit.
     */
    val audioOutput: AudioOutputService? = null,
)
