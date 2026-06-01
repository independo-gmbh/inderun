import Foundation

public final class ProviderRegistry: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var providers: [String: any ProviderAdapter] = [:]
    
    public init() {}
    
    public func register(_ provider: any ProviderAdapter) throws {
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
    }
}
