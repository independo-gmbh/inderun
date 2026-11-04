import Foundation
import IndeRunContracts

// MARK: - Services Interfaces
public protocol ConnectivityService: Sendable {
    func isOnline() async -> Bool
}

public enum ThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public protocol DeviceConstraintsService: Sendable {
    func getThermalState() async -> ThermalState?
    func isLowPowerModeEnabled() async -> Bool?
}

// Provide default implementations to make implementation of constraints service optional
public extension DeviceConstraintsService {
    func getThermalState() async -> ThermalState? { nil }
    func isLowPowerModeEnabled() async -> Bool? { nil }
}

public protocol SecureStorageService: Sendable {
    func getSecret(slotId: String) async -> String?
    func setSecret(slotId: String, secret: String) async
    func deleteSecret(slotId: String) async
}

public protocol ClockService: Sendable {
    func now() -> Int64
    func monotonicNow() -> Double?
}

public extension ClockService {
    func monotonicNow() -> Double? { nil }
}

public protocol HttpClientService: Sendable {
    func send(request: HttpRequest) async throws -> HttpResponse
}

/// A streamed HTTP response: the status line and headers are resolved first, and
/// the body is delivered incrementally as raw byte chunks.
///
/// The head is deliberately separated from the body so a caller can classify a
/// non-2xx response (mapping it through the normal HTTP error taxonomy) before
/// deciding to interpret the body as a protocol stream. Chunk boundaries are
/// transport artifacts and carry no meaning: a chunk may split a protocol frame
/// or even a multi-byte UTF-8 sequence, so consumers must buffer and decode
/// incrementally rather than treating a chunk as a unit.
public struct HttpStreamResponse: Sendable {
    public let status: Int
    public let statusText: String
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>

    public init(
        status: Int,
        statusText: String,
        headers: [String: String],
        body: AsyncThrowingStream<Data, Error>
    ) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }
}

/// Optional host capability for HTTP responses that must be consumed while they
/// are still arriving — the transport requirement behind Mode 2 streaming over
/// the network (for example server-sent events).
///
/// It is a separate protocol rather than a member of ``HttpClientService``
/// because it is genuinely optional: a host that cannot stream simply omits it,
/// and providers report that as `streamingAvailable: false` in their dynamic
/// capabilities, which the route planner turns into an inspectable
/// `streaming_unavailable` rejection.
public protocol HttpStreamingClientService: Sendable {
    /// Dispatches a normalized HTTP request and returns once the response head is
    /// available, leaving the body to be consumed incrementally.
    ///
    /// `HttpRequest.timeoutMs` bounds the wait for the response head only — the
    /// time to first byte. It cannot bound total duration, since a stream is
    /// open-ended by nature; cancel the surrounding `Task` to stop a stream that
    /// runs too long.
    func stream(request: HttpRequest) async throws -> HttpStreamResponse
}

public protocol TelemetryService: Sendable {
    func emit(event: TelemetryEvent)
}

/// Resolves the opaque `delivery.destinationRef` of an artifact request to a place the
/// application chose -- a file it will hand to a player, a cache it manages -- and writes the
/// finished artifact there (ADR 017). A request names a reference, never a path, so a request
/// that came from a webview cannot address arbitrary storage.
public protocol ArtifactDestinationService: Sendable {
    /// Whether `destinationRef` names a destination this host can write the requested media to.
    /// Called before routing; `false` refuses the request.
    func accepts(destinationRef: String, mediaTypes: [String]?) async -> Bool
    /// Writes the finished artifact's bytes to the destination. A failure fails the run: it is
    /// committed by then, so it never falls back.
    func write(destinationRef: String, artifact: MediaArtifact, bytes: Data) async throws
}

/// The sample encoding of an audio output session. Always signed 16-bit little-endian PCM.
public enum AudioOutputEncoding: String, Sendable {
    case pcmS16le = "pcm_s16le"
}

/// The PCM format of one audio output session. Every host accepts mono signed 16-bit
/// little-endian samples at 8000 to 48000 Hz inclusive; a service may refuse further rates
/// with the same `audio_format_unsupported` code (`CapabilityMismatch`).
public struct AudioOutputFormat: Sendable, Equatable {
    /// Samples per second, 8000 to 48000 inclusive.
    public let sampleRate: Int
    /// Always mono.
    public let channels: Int
    /// Always signed 16-bit little-endian PCM.
    public let encoding: AudioOutputEncoding

    public init(sampleRate: Int, channels: Int = 1, encoding: AudioOutputEncoding = .pcmS16le) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
    }
}

/// One playback session. Sessions of one service are independent: stopping one does not
/// disturb another.
///
/// The normal path is `write(_:)` for each chunk, then `drain()`, then `stop()`; a provider's
/// cancel path is `stop()`.
///
/// A session ends once: by `stop()`, or by the system taking the output away (an interruption,
/// the output stopping), which ends it with `Unavailable` and `details.code`
/// `audio_output_interrupted`.
public protocol AudioOutputSession: Sendable {
    /// Hands samples to the host. Returns once the host has buffered them, so a caller that
    /// awaits each write is paced by the output (backpressure). The first write is the first
    /// possible audible effect. After `stop()`, returns at once without effect; after the
    /// system ended the session, throws its error.
    ///
    /// Honours `Task` cancellation (throws `CancellationError`) like
    /// ``HttpStreamingClientService/stream(request:)``; a provider's cancel path is `stop()`.
    func write(_ samples: [Int16]) async throws
    /// Returns when everything written has played. After `stop()`, returns at once without
    /// effect; after the system ended the session, throws its error.
    ///
    /// Honours `Task` cancellation (throws `CancellationError`) like
    /// ``HttpStreamingClientService/stream(request:)``; a provider's cancel path is `stop()`.
    func drain() async throws
    /// Ends the session now: discards buffered audio and releases the output. Idempotent, and
    /// nothing renders after it.
    func stop()
    /// Milliseconds from `open(format:)` to the first frame the host observed leaving the
    /// output; `nil` until then.
    func firstAudioMs() -> Double?
}

/// Plays PCM for providers that synthesize audio themselves.
public protocol AudioOutputService: Sendable {
    /// Opens a playback session. Makes no sound, and validates the format: one outside the
    /// rule on ``AudioOutputFormat`` throws `CapabilityMismatch` with
    /// `details.code` `audio_format_unsupported`. Honours `Task` cancellation (throws
    /// `CancellationError`) like ``HttpStreamingClientService/stream(request:)``.
    func open(format: AudioOutputFormat) async throws -> any AudioOutputSession
}

// MARK: - HostServices Container
public struct HostServices: Sendable {
    public let connectivity: ConnectivityService
    public let deviceConstraints: DeviceConstraintsService?
    public let secureStorage: SecureStorageService?
    public let clock: ClockService?
    public let httpClient: HttpClientService?
    /// HTTP client service for responses consumed while still arriving. Absent on
    /// hosts that cannot stream a response body.
    public let streamingHttpClient: HttpStreamingClientService?
    public let telemetry: TelemetryService?
    /// Application destinations for artifact requests that carry `delivery.destinationRef`.
    /// Absent means the host has none, and such a request is refused before routing.
    public let artifactDestinations: ArtifactDestinationService?
    /// PCM playback for providers that synthesize audio themselves. Absent on hosts that
    /// cannot play audio; such a provider refuses before commit.
    public let audioOutput: AudioOutputService?

    public init(
        connectivity: ConnectivityService,
        deviceConstraints: DeviceConstraintsService? = nil,
        secureStorage: SecureStorageService? = nil,
        clock: ClockService? = nil,
        httpClient: HttpClientService? = nil,
        streamingHttpClient: HttpStreamingClientService? = nil,
        telemetry: TelemetryService? = nil,
        artifactDestinations: ArtifactDestinationService? = nil,
        audioOutput: AudioOutputService? = nil
    ) {
        self.connectivity = connectivity
        self.deviceConstraints = deviceConstraints
        self.secureStorage = secureStorage
        self.clock = clock
        self.httpClient = httpClient
        self.streamingHttpClient = streamingHttpClient
        self.telemetry = telemetry
        self.artifactDestinations = artifactDestinations
        self.audioOutput = audioOutput
    }
}
