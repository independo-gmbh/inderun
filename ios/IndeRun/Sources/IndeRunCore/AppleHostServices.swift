import Foundation
import IndeRunContracts
import Network
import Security

public final class NetworkConnectivityService: ConnectivityService, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue

    public init(queueLabel: String = "dev.inderun.connectivity") {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: queueLabel)
        self.monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public func isOnline() async -> Bool {
        monitor.currentPath.status == .satisfied
    }
}

public final class SystemClockService: ClockService, Sendable {
    public init() {}

    public func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public func monotonicNow() -> Double? {
        ProcessInfo.processInfo.systemUptime * 1000
    }
}

public final class KeychainSecureStorageService: SecureStorageService, Sendable {
    private let service: String

    public init(service: String = "dev.inderun.credentials") {
        self.service = service
    }

    public func getSecret(slotId: String) async -> String? {
        guard !slotId.isEmpty else { return nil }

        var query = baseQuery(slotId: slotId)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public func setSecret(slotId: String, secret: String) async {
        guard !slotId.isEmpty, let data = secret.data(using: .utf8) else { return }

        var addQuery = baseQuery(slotId: slotId)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery = baseQuery(slotId: slotId)
            let attributes = [kSecValueData as String: data]
            SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        }
    }

    public func deleteSecret(slotId: String) async {
        guard !slotId.isEmpty else { return }
        SecItemDelete(baseQuery(slotId: slotId) as CFDictionary)
    }

    private func baseQuery(slotId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slotId
        ]
    }
}

public final class URLSessionHttpClientService: HttpClientService, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(request: HttpRequest) async throws -> HttpResponse {
        guard let url = URL(string: request.url) else {
            throw createInternal(message: "Invalid HTTP request URL.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        if let timeoutMs = request.timeoutMs {
            urlRequest.timeoutInterval = Double(timeoutMs) / 1000.0
        }
        request.headers?.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body.utf8)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw createInternal(message: "HTTP transport returned a non-HTTP response.")
        }

        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String {
                result[key] = String(describing: pair.value)
            }
        }

        return HttpResponse(
            status: httpResponse.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            headers: headers,
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

public enum DefaultHostServices {
    public static func make(
        connectivity: ConnectivityService = NetworkConnectivityService(),
        deviceConstraints: DeviceConstraintsService? = nil,
        secureStorage: SecureStorageService = KeychainSecureStorageService(),
        clock: ClockService = SystemClockService(),
        httpClient: HttpClientService = URLSessionHttpClientService(),
        telemetry: TelemetryService? = nil
    ) -> HostServices {
        HostServices(
            connectivity: connectivity,
            deviceConstraints: deviceConstraints,
            secureStorage: secureStorage,
            clock: clock,
            httpClient: httpClient,
            telemetry: telemetry
        )
    }
}
