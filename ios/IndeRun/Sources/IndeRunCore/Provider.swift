import Foundation
import IndeRunContracts

// MARK: - ProviderDescriptor
public struct ProviderDescriptor: Codable, Sendable {
    public enum ProviderType: String, Codable, Sendable {
        case local
        case edge
        case cloud
    }
    
    public enum TransportType: String, Codable, Sendable {
        case inProcess = "in_process"
        case systemService = "system_service"
        case http
        case sse
        case realtime
    }
    
    public enum StreamingStyle: String, Codable, Sendable {
        case tokens
        case chunks
        case snapshots
    }
    
    public struct SupportsCapabilities: Codable, Sendable {
        public let run: Bool
        public let streaming: Bool
        public let realtime: Bool
        public let tools: Bool
        public let reasoningEvents: Bool
        public let structuredOutput: Bool
        public let multimodal: Bool
        
        public init(
            run: Bool,
            streaming: Bool,
            realtime: Bool,
            tools: Bool,
            reasoningEvents: Bool,
            structuredOutput: Bool,
            multimodal: Bool
        ) {
            self.run = run
            self.streaming = streaming
            self.realtime = realtime
            self.tools = tools
            self.reasoningEvents = reasoningEvents
            self.structuredOutput = structuredOutput
            self.multimodal = multimodal
        }
    }
    
    public enum CancelSemantics: String, Codable, Sendable {
        case hard
        case soft
        case none
    }
    
    public struct ResourceLimits: Codable, Sendable {
        public let maxInputTokens: Int?
        public let maxOutputTokens: Int?
        public let maxImageBytes: Int?
        public let maxAudioSeconds: Int?
        
        public init(
            maxInputTokens: Int? = nil,
            maxOutputTokens: Int? = nil,
            maxImageBytes: Int? = nil,
            maxAudioSeconds: Int? = nil
        ) {
            self.maxInputTokens = maxInputTokens
            self.maxOutputTokens = maxOutputTokens
            self.maxImageBytes = maxImageBytes
            self.maxAudioSeconds = maxAudioSeconds
        }
    }
    
    public struct PrivacyDescriptor: Codable, Sendable {
        public let dataLeavesDevice: Bool
        public let regions: [String]?
        
        public init(dataLeavesDevice: Bool, regions: [String]? = nil) {
            self.dataLeavesDevice = dataLeavesDevice
            self.regions = regions
        }
    }
    
    public let id: String
    public let type: ProviderType
    public let transport: TransportType
    public let streamingStyle: StreamingStyle?
    public let supports: SupportsCapabilities
    public let cancel: CancelSemantics
    public let tasks: [String]
    public let limits: ResourceLimits?
    public let privacy: PrivacyDescriptor?
    
    public init(
        id: String,
        type: ProviderType,
        transport: TransportType,
        streamingStyle: StreamingStyle? = nil,
        supports: SupportsCapabilities,
        cancel: CancelSemantics,
        tasks: [String],
        limits: ResourceLimits? = nil,
        privacy: PrivacyDescriptor? = nil
    ) {
        self.id = id
        self.type = type
        self.transport = transport
        self.streamingStyle = streamingStyle
        self.supports = supports
        self.cancel = cancel
        self.tasks = tasks
        self.limits = limits
        self.privacy = privacy
    }
}

// MARK: - ProviderDynamicCapabilities
public struct ProviderDynamicCapabilities: Codable, Sendable {
    public let available: Bool
    
    public init(available: Bool) {
        self.available = available
    }
}

// MARK: - RunContext
public struct RunContext: Sendable {
    public let runId: String
    public let hostServices: HostServices
    
    public init(runId: String, hostServices: HostServices) {
        self.runId = runId
        self.hostServices = hostServices
    }
}

// MARK: - ProviderAdapter Protocol
public protocol ProviderAdapter: Sendable {
    func describe() -> ProviderDescriptor
    func capabilities(host: HostServices) async -> ProviderDynamicCapabilities
    func run(request: TaskRequest, context: RunContext) async throws -> TaskResult
}
