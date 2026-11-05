import Foundation
import IndeRunContracts

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

        func runtime(for key: String, make: () -> ArticulinoRuntime) -> ArticulinoRuntime {
            if let existing = runtimes[key] { return existing }
            let created = make()
            runtimes[key] = created
            return created
        }
    }

    private enum Resolution {
        case ready(ArticulinoRuntime)
        case refused(NeuralSpeechAvailability)
    }

    private let options: OnnxNeuralSpeechRuntimeOptions
    private let state = State()

    public init(options: OnnxNeuralSpeechRuntimeOptions = .init()) {
        self.options = options
    }

    public func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        switch await resolve(modelPackage, verify: false) {
        case let .ready(runtime): return await runtime.availability(modelPackage)
        case let .refused(refusal): return refusal
        }
    }

    public func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        switch await resolve(modelPackage, verify: true) {
        case let .ready(runtime): return await runtime.prepare(modelPackage)
        case let .refused(refusal): return refusal
        }
    }

    public func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch await self.resolve(input.modelPackage, verify: false) {
                    case let .refused(refusal):
                        throw NeuralSpeechRuntimeError(kind: .unavailable, message: refusal.reason ?? "unavailable")
                    case let .ready(runtime):
                        for try await chunk in runtime.synthesize(input) { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolve(_ modelPackage: ModelPackage, verify: Bool) async -> Resolution {
        let pipeline = modelPackage.speech?.pipeline
        guard pipeline == "articulino" else {
            return .refused(NeuralSpeechAvailability(available: false, reason: "unsupported pipeline '\(pipeline ?? "")'"))
        }
        if let needed = modelPackage.limits?.memBytes {
            let device = options.deviceMemoryBytes?() ?? ProcessInfo.processInfo.physicalMemory
            if needed > 0, UInt64(needed) > device {
                return .refused(NeuralSpeechAvailability(
                    available: false, reason: "insufficient memory: package needs \(needed) bytes, device has \(device) bytes"
                ))
            }
        }
        let directory: URL
        do {
            directory = try LoadedSessionBox.resolveDirectory(modelPackage)
            if verify { try LoadedSessionBox.verifyChecksums(modelPackage, directory: directory) }
        } catch let error as OnnxRuntimeError {
            return .refused(NeuralSpeechAvailability(available: false, reason: error.message))
        } catch {
            return .refused(NeuralSpeechAvailability(available: false, reason: String(describing: error)))
        }
        let options = options
        let runtime = await state.runtime(for: "\(modelPackage.id)@\(modelPackage.version ?? "")") {
            ArticulinoRuntime(options: ArticulinoRuntimeOptions(
                executor: OnnxSpeechGraphExecutor(directory: directory, threads: options.threads),
                files: DirectoryPackageFiles(directory: directory),
                noise: options.noise,
                speed: options.speed,
                pauseMs: options.pauseMs
            ))
        }
        return .ready(runtime)
    }
}
