import Foundation

/// How a provider takes part in preparation (ADR 019).
public struct ProviderRegistrationOptions: Sendable {
    /// Lets `prepare`, explicit or on the first run, start this provider's platform download. Off
    /// by default: a download can use mobile data, so it is the application's decision. Off, a call
    /// can still allow one with `PrepareRequest.allowDownload`.
    public var autoDownload: Bool

    public init(autoDownload: Bool = false) {
        self.autoDownload = autoDownload
    }
}

public final class ProviderRegistry: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var providers: [String: any ProviderAdapter] = [:]
    private var options: [String: ProviderRegistrationOptions] = [:]

    public init() {}

    public func register(
        _ provider: any ProviderAdapter,
        options: ProviderRegistrationOptions = ProviderRegistrationOptions()
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let descriptor = provider.describe()
        guard !descriptor.id.isEmpty else {
            throw createInternal(message: "Provider must have a non-empty ID.")
        }

        if providers[descriptor.id] != nil {
            throw createInternal(message: "Provider with ID \"\(descriptor.id)\" is already registered.")
        }

        providers[descriptor.id] = provider
        self.options[descriptor.id] = options
    }

    /// Whether `prepare` may start this provider's platform download on its own.
    public func allowsAutoDownload(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return options[id]?.autoDownload == true
    }

    public func get(id: String) -> (any ProviderAdapter)? {
        lock.lock()
        defer { lock.unlock() }
        return providers[id]
    }

    public func list() -> [any ProviderAdapter] {
        lock.lock()
        defer { lock.unlock() }
        return Array(providers.values)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        providers.removeAll()
        options.removeAll()
    }
}
