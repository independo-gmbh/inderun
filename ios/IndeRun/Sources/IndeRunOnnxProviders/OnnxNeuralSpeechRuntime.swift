import Foundation
import IndeRunContracts
import IndeRunCore

/// Options of an ``OnnxNeuralSpeechRuntime``.
public struct OnnxNeuralSpeechRuntimeOptions: Sendable {
    /// ONNX Runtime intra-op threads; default `min(4, activeProcessorCount)`.
    public let threads: Int?
    public let noise: NoiseSource?
    public let speed: Float
    public let pauseMs: Int
    /// The device memory `limits.memBytes` is compared with; default `ProcessInfo.physicalMemory`.
    public let deviceMemoryBytes: (@Sendable () -> UInt64)?

    public init(
        threads: Int? = nil, noise: NoiseSource? = nil, speed: Float = 1.0, pauseMs: Int = 150,
        deviceMemoryBytes: (@Sendable () -> UInt64)? = nil
    ) {
        self.threads = threads
        self.noise = noise
        self.speed = speed
        self.pauseMs = pauseMs
        self.deviceMemoryBytes = deviceMemoryBytes
    }
}

/// The ``NeuralSpeechRuntime`` for neural speech packages on Apple platforms: resolves the package
/// directory (`filesystem`, `bundled` or `app_managed` sources), checks the declared checksums at
/// `prepare`, and runs the Articulino pipeline through ONNX Runtime. One pipeline runtime is
/// built and cached per package id and version. A package whose `limits.memBytes` exceeds the
/// device's physical memory is refused at `availability`, `prepare` and `synthesize`, before
/// anything loads.
public final class OnnxNeuralSpeechRuntime: NeuralSpeechRuntime, @unchecked Sendable {
    private actor State {
        private var runtimes: [String: ArticulinoRuntime] = [:]

        func runtime(for key: String, make: () -> ArticulinoRuntime?) -> ArticulinoRuntime? {
            if let existing = runtimes[key] { return existing }
            guard let created = make() else { return nil }
            runtimes[key] = created
            return created
        }

        func clear() {
            runtimes.removeAll()
        }

        var count: Int { runtimes.count }
    }

    private enum Resolution {
        case ready(ArticulinoRuntime)
        case refused(NeuralSpeechAvailability)
    }

    private let options: OnnxNeuralSpeechRuntimeOptions
    private let state = State()
    private let lifecycle = SpeechRuntimeLifecycle()

    /// Test hook: builds the executor of a package directory; `nil` builds the ONNX Runtime one.
    var makeExecutor: (@Sendable (URL) -> any SpeechGraphExecutor)?

    public init(options: OnnxNeuralSpeechRuntimeOptions = .init()) {
        self.options = options
    }

    public func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        if lifecycle.isClosed { return Self.closedAvailability }
        switch await resolve(modelPackage, verify: false) {
        case let .ready(runtime): return await runtime.availability(modelPackage)
        case let .refused(refusal): return refusal
        }
    }

    public func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        if lifecycle.isClosed { return Self.closedAvailability }
        switch await resolve(modelPackage, verify: true) {
        case let .ready(runtime): return await runtime.prepare(modelPackage)
        case let .refused(refusal): return refusal
        }
    }

    /// Forwards to the Articulino hook; any other pipeline keeps the text (it is refused at `availability`).
    public func normalizeText(_ modelPackage: ModelPackage, text: String, locale: String) -> String {
        guard !lifecycle.isClosed, modelPackage.speech?.pipeline == "articulino" else { return text }
        return ArticulinoRuntime.normalizeText(modelPackage, text: text, locale: locale)
    }

    /// Terminal and idempotent; see ``NeuralSpeechRuntime/close()``. Releases every cached pipeline's
    /// executor once the graph calls in flight have returned.
    public func close() async {
        await lifecycle.close()
        // Nothing resolves a pipeline after close; drop them so their graphs and files can be freed.
        await state.clear()
    }

    /// Test hook: how many pipeline runtimes are cached.
    func cachedPipelineCount() async -> Int {
        await state.count
    }

    private static let closedAvailability = NeuralSpeechAvailability(available: false, reason: "runtime closed")

    public func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        ComposedNeuralSpeechRuntime.stream { continuation in
            switch await self.resolve(input.modelPackage, verify: false) {
            case let .refused(refusal):
                if self.lifecycle.isClosed { throw NeuralSpeechRuntimeError.runtimeClosed }
                throw NeuralSpeechRuntimeError(kind: .unavailable, message: refusal.reason ?? "unavailable")
            case let .ready(runtime):
                for try await chunk in runtime.synthesize(input) { continuation.yield(chunk) }
            }
        }
    }

    private func resolve(_ modelPackage: ModelPackage, verify: Bool) async -> Resolution {
        if lifecycle.isClosed { return .refused(Self.closedAvailability) }
        let pipeline = modelPackage.speech?.pipeline
        guard pipeline == "articulino" else {
            return .refused(NeuralSpeechAvailability(available: false, reason: "unsupported pipeline '\(pipeline ?? "")'"))
        }
        if let reason = ComposedNeuralSpeechRuntime.memoryRefusal(modelPackage, deviceMemoryBytes: options.deviceMemoryBytes) {
            return .refused(NeuralSpeechAvailability(available: false, reason: reason))
        }
        let directory: URL
        do {
            directory = try ModelPackageDirectory.resolve(modelPackage)
            if verify { try ModelPackageDirectory.verifyChecksums(modelPackage, directory: directory) }
        } catch let error as ModelPackageDirectoryError {
            return .refused(NeuralSpeechAvailability(available: false, reason: error.message))
        } catch {
            return .refused(NeuralSpeechAvailability(available: false, reason: String(describing: error)))
        }
        let options = options
        let lifecycle = lifecycle
        let makeExecutor = makeExecutor
        let runtime = await state.runtime(for: "\(modelPackage.id)@\(modelPackage.version ?? "")") {
            guard let executor = lifecycle.guarded(make: {
                makeExecutor?(directory) ?? OnnxSpeechGraphExecutor(directory: directory, threads: options.threads)
            }) else { return nil }
            return ArticulinoRuntime(options: ArticulinoRuntimeOptions(
                executor: executor,
                files: DirectoryPackageFiles(directory: directory),
                noise: options.noise,
                speed: options.speed,
                pauseMs: options.pauseMs
            ))
        }
        guard let runtime else { return .refused(Self.closedAvailability) }
        return .ready(runtime)
    }
}
