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

/// Streaming HTTP client backed by `URLSession.bytes(for:)`.
///
/// `URLSession.AsyncBytes` yields individual bytes, so bytes are re-accumulated
/// into `Data` chunks here and flushed on newline (or once the buffer grows past
/// ``maxBufferBytes``). Chunk boundaries carry no meaning by contract; flushing
/// at newlines simply avoids withholding data that has already arrived, which
/// would stall any line-oriented protocol carried over the stream.
public final class URLSessionStreamingHttpClientService: HttpStreamingClientService, Sendable {
    private static let maxBufferBytes = 16 * 1024
    private static let newline: UInt8 = 0x0A

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(request: HttpRequest) async throws -> HttpStreamResponse {
        guard let url = URL(string: request.url) else {
            throw createInternal(message: "Invalid HTTP request URL.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        if let timeoutMs = request.timeoutMs {
            // Bounds the wait for the response head only: URLSession applies
            // timeoutInterval to the time between data arriving, and an
            // established stream keeps resetting it.
            urlRequest.timeoutInterval = Double(timeoutMs) / 1000.0
        }
        request.headers?.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body.utf8)
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw createInternal(message: "HTTP transport returned a non-HTTP response.")
        }

        // Lower-cased so header lookups are case-insensitive at the call site.
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String {
                result[key.lowercased()] = String(describing: pair.value)
            }
        }

        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == Self.newline || buffer.count >= Self.maxBufferBytes {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return HttpStreamResponse(
            status: httpResponse.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            headers: headers,
            body: body
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
        streamingHttpClient: HttpStreamingClientService = URLSessionStreamingHttpClientService(),
        telemetry: TelemetryService? = nil
    ) -> HostServices {
        HostServices(
            connectivity: connectivity,
            deviceConstraints: deviceConstraints,
            secureStorage: secureStorage,
            clock: clock,
            httpClient: httpClient,
            streamingHttpClient: streamingHttpClient,
            telemetry: telemetry
        )
    }
}
