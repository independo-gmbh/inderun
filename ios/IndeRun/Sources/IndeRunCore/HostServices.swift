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

public protocol TelemetryService: Sendable {
    func emit(event: TelemetryEvent)
}

// MARK: - HostServices Container
public struct HostServices: Sendable {
    public let connectivity: ConnectivityService
    public let deviceConstraints: DeviceConstraintsService?
    public let secureStorage: SecureStorageService?
    public let clock: ClockService?
    public let httpClient: HttpClientService?
    public let telemetry: TelemetryService?

    public init(
        connectivity: ConnectivityService,
        deviceConstraints: DeviceConstraintsService? = nil,
        secureStorage: SecureStorageService? = nil,
        clock: ClockService? = nil,
        httpClient: HttpClientService? = nil,
        telemetry: TelemetryService? = nil
    ) {
        self.connectivity = connectivity
        self.deviceConstraints = deviceConstraints
        self.secureStorage = secureStorage
        self.clock = clock
        self.httpClient = httpClient
        self.telemetry = telemetry
    }
}
