import Foundation
import IndeRunContracts
import IndeRunCore
import IndeRunNeuralSpeech
#if canImport(CoreAI)
import CoreAI
#endif

/// Options of a ``CoreAINeuralSpeechRuntime``.
public struct CoreAINeuralSpeechRuntimeOptions: Sendable {
    public let noise: NoiseSource?
    public let speed: Float
    public let pauseMs: Int
    /// The device memory `limits.memBytes` is compared with; default `ProcessInfo.physicalMemory`.
    public let deviceMemoryBytes: (@Sendable () -> UInt64)?

    public init(noise: NoiseSource? = nil, speed: Float = 1.0, pauseMs: Int = 150, deviceMemoryBytes: (@Sendable () -> UInt64)? = nil) {
        self.noise = noise
        self.speed = speed
        self.pauseMs = pauseMs
        self.deviceMemoryBytes = deviceMemoryBytes
    }
}

/// The ``NeuralSpeechRuntime`` for `format: "coreai"` neural speech packages on Apple platforms
/// (iOS 27 / macOS 27): resolves the package directory as the ONNX runtime does, checks the
/// Articulino package metadata, the graph references and their files, and that the config and every
/// voice file exist, and runs the Articulino pipeline through ``CoreAISpeechGraphExecutor``.
/// One pipeline runtime is built and cached per package id and version.
///
/// A `.aimodel` must be specialized for the device before it loads, which can take minutes. That is
/// the consent-gated step: `availability` reports `readiness: .notPrepared` while any graph file is
/// missing from `AIModelCache`, and only `prepare` specializes. `synthesize` refuses until a
/// `prepare` succeeded, so neither it nor `availability` ever specializes. Below iOS 27 / macOS 27,
/// or on an SDK without Core AI, every call refuses with ``CoreAISupport/unavailableReason``.
public final class CoreAINeuralSpeechRuntime: NeuralSpeechRuntime, @unchecked Sendable {
    private actor State {
        private var runtimes: [String: ArticulinoRuntime] = [:]
        private var prepared: Set<String> = []
        /// Why the last `prepare` of a package failed, by package key.
        private var failures: [String: String] = [:]
        /// Specializations in flight, by file, so concurrent `prepare` calls specialize a file once.
        private var specializing: [URL: Task<Void, Error>] = [:]

        func runtime(for key: String, make: () -> ArticulinoRuntime?) -> ArticulinoRuntime? {
            if let existing = runtimes[key] { return existing }
            guard let created = make() else { return nil }
            runtimes[key] = created
            return created
        }

        func finishPrepare(_ key: String, _ result: NeuralSpeechAvailability) {
            if result.available {
                prepared.insert(key)
                failures[key] = nil
            } else {
                prepared.remove(key)
                failures[key] = result.reason
            }
        }

        func isPrepared(_ key: String) -> Bool {
            prepared.contains(key)
        }

        func preparation(_ key: String) -> (prepared: Bool, failure: String?) {
            (prepared.contains(key), failures[key])
        }

        /// Joins the specialization of `url` in flight, or starts `run` as it.
        func specialization(of url: URL, _ run: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
            if let running = specializing[url] { return running }
            let task = Task { try await run() }
            specializing[url] = task
            return task
        }

        func finishSpecialization(of url: URL) {
            specializing[url] = nil
        }
    }

    private struct Resolved {
        let key: String
        let directory: URL
        /// The distinct graph files, in the order of their roles.
        let files: [String]
        /// Every graph reference, by role in sorted order.
        let references: [(role: String, reference: CoreAIGraphReference)]
    }

    private enum Resolution {
        case ready(Resolved)
        case refused(NeuralSpeechAvailability)
    }

    private let options: CoreAINeuralSpeechRuntimeOptions
    private let state = State()

    // Test hooks, consulted before any Core AI symbol. Set them before the first call: they are read
    // without synchronization.
    /// `nil` uses ``CoreAISupport/isAvailable``.
    var isAvailableOverride: Bool?
    /// `nil` asks `AIModelCache.default`.
    var isSpecialized: ((URL) -> Bool)?
    /// `nil` runs `AIModel.specialize(contentsOf:options:)`.
    var specialize: ((URL) async throws -> Void)?
    /// The inference functions an asset declares, `nil` when it has no summary. `nil` reads the
    /// `AIModelAsset` summary.
    var assetFunctionNames: ((URL) throws -> [String]?)?

    public init(options: CoreAINeuralSpeechRuntimeOptions = .init()) {
        self.options = options
    }

    public func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        switch resolve(modelPackage, verify: false) {
        case let .refused(refusal):
            return refusal
        case let .ready(resolved):
            // Once prepared in this process the models are loaded, so the cache is not probed on the
            // routing hot path; a purge is observed by a runtime that has not prepared the package.
            if await state.isPrepared(resolved.key) {
                return NeuralSpeechAvailability(available: true, readiness: .cold)
            }
            let pending = resolved.files.contains { !specialized(resolved.directory.appendingPathComponent($0)) }
            return NeuralSpeechAvailability(available: true, readiness: pending ? .notPrepared : .cold)
        }
    }

    /// Every outcome, an early refusal included, is remembered for the next `synthesize`.
    public func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        let result = await prepareResolving(modelPackage)
        await state.finishPrepare(Self.key(modelPackage), result)
        return result
    }

    private func prepareResolving(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        let resolved: Resolved
        switch resolve(modelPackage, verify: true) {
        case let .refused(refusal): return refusal
        case let .ready(ready): resolved = ready
        }
        if let refusal = checkAssetFunctions(resolved) {
            return refusal
        }
        // Runs on every prepare: a cache hit is cheap, and a purged cache is re-specialized here.
        for file in resolved.files {
            let url = resolved.directory.appendingPathComponent(file)
            guard !specialized(url) else { continue }
            let specialization = await state.specialization(of: url) { try await self.specializeFile(url) }
            let outcome = await specialization.result
            await state.finishSpecialization(of: url)
            if case let .failure(error) = outcome {
                let message = (error as? NeuralSpeechRuntimeError)?.message ?? error.localizedDescription
                return NeuralSpeechAvailability(available: false, reason: "specialization failed: \(file): \(message)")
            }
        }
        guard let runtime = await pipelineRuntime(resolved) else {
            return NeuralSpeechAvailability(available: false, reason: CoreAISupport.unavailableReason)
        }
        return await runtime.prepare(modelPackage)
    }

    public func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        ComposedNeuralSpeechRuntime.stream { continuation in
            switch self.resolve(input.modelPackage, verify: false) {
            case let .refused(refusal):
                throw NeuralSpeechRuntimeError(kind: .unavailable, message: refusal.reason ?? "unavailable")
            case let .ready(resolved):
                let preparation = await self.state.preparation(resolved.key)
                guard preparation.prepared, let runtime = await self.pipelineRuntime(resolved) else {
                    let reason = preparation.failure.map { ": \($0)" } ?? ""
                    throw NeuralSpeechRuntimeError(kind: .unavailable, message: "model not prepared: \(resolved.key)\(reason)")
                }
                for try await chunk in runtime.synthesize(input) { continuation.yield(chunk) }
            }
        }
    }

    /// Records the package as prepared without loading it (tests of the prepared state).
    func markPrepared(_ modelPackage: ModelPackage) async {
        await state.finishPrepare(Self.key(modelPackage), NeuralSpeechAvailability(available: true))
    }

    // MARK: - Resolution

    private func resolve(_ modelPackage: ModelPackage, verify: Bool) -> Resolution {
        guard isAvailableOverride ?? CoreAISupport.isAvailable else {
            return refused(CoreAISupport.unavailableReason)
        }
        guard modelPackage.format == .coreai else {
            return refused("unsupported format '\(modelPackage.format.rawValue)'")
        }
        let pipeline = modelPackage.speech?.pipeline
        guard pipeline == "articulino", let speech = modelPackage.speech else {
            return refused("unsupported pipeline '\(pipeline ?? "")'")
        }
        if let reason = ComposedNeuralSpeechRuntime.memoryRefusal(modelPackage, deviceMemoryBytes: options.deviceMemoryBytes) {
            return refused(reason)
        }
        let directory: URL
        do {
            directory = try ModelPackageDirectory.resolve(modelPackage)
            if verify { try ModelPackageDirectory.verifyChecksums(modelPackage, directory: directory) }
        } catch let error as ModelPackageDirectoryError {
            return refused(error.message)
        } catch {
            return refused(String(describing: error))
        }
        // An incomplete package is refused here, before any graph file is specialized for it.
        let metadata = ArticulinoRuntime.checkPackage(modelPackage)
        guard metadata.available else {
            return .refused(metadata)
        }
        var files: [String] = []
        var references: [(role: String, reference: CoreAIGraphReference)] = []
        for (role, value) in speech.graphs.sorted(by: { $0.key < $1.key }) {
            let file: String
            do {
                let reference = try CoreAIGraphReference(role: role, value: value)
                file = reference.file
                try checkPackageFileName(file)
                references.append((role, reference))
            } catch let error as NeuralSpeechRuntimeError {
                return refused(error.message)
            } catch {
                return refused(String(describing: error))
            }
            // An .aimodel may be a file or a directory; either counts.
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
                return refused("model files missing: \(file)")
            }
            if !files.contains(file) { files.append(file) }
        }
        // The pipeline reads the config and every voice file only after specialization, so their
        // absence is refused here instead.
        let assets = [speech.frontend?.assets?["config"]].compactMap { $0 } + speech.voices.compactMap(\.file)
        for file in assets {
            do {
                try checkPackageFileName(file)
            } catch let error as NeuralSpeechRuntimeError {
                return refused(error.message)
            } catch {
                return refused(String(describing: error))
            }
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
                return refused("model files missing: \(file)")
            }
        }
        return .ready(Resolved(key: Self.key(modelPackage), directory: directory, files: files, references: references))
    }

    private static func key(_ modelPackage: ModelPackage) -> String {
        "\(modelPackage.id)@\(modelPackage.version ?? "")"
    }

    /// Refuses a role whose function the asset does not declare, before minutes of specialization are
    /// spent on it. An asset without a summary is not checked; `load` still finds a missing function.
    private func checkAssetFunctions(_ resolved: Resolved) -> NeuralSpeechAvailability? {
        for file in resolved.files {
            let names: [String]?
            do {
                names = try functionNames(resolved.directory.appendingPathComponent(file), file: file)
            } catch {
                let message = (error as? NeuralSpeechRuntimeError)?.message ?? error.localizedDescription
                return NeuralSpeechAvailability(available: false, reason: message)
            }
            guard let names else { continue }
            for (role, reference) in resolved.references where reference.file == file && !names.contains(reference.function) {
                return NeuralSpeechAvailability(
                    available: false, reason: "graph function missing: \(role): \(reference.function) in \(file)"
                )
            }
        }
        return nil
    }

    private func refused(_ reason: String) -> Resolution {
        .refused(NeuralSpeechAvailability(available: false, reason: reason))
    }

    /// The cached pipeline runtime of the package, or `nil` where Core AI cannot run.
    private func pipelineRuntime(_ resolved: Resolved) async -> ArticulinoRuntime? {
        let options = options
        return await state.runtime(for: resolved.key) {
            guard let executor = Self.makeExecutor(directory: resolved.directory) else { return nil }
            return ArticulinoRuntime(options: ArticulinoRuntimeOptions(
                executor: executor,
                files: DirectoryPackageFiles(directory: resolved.directory),
                noise: options.noise,
                speed: options.speed,
                pauseMs: options.pauseMs
            ))
        }
    }

    // MARK: - Core AI

    private static func makeExecutor(directory: URL) -> (any SpeechGraphExecutor)? {
        #if canImport(CoreAI)
        if #available(iOS 27, macOS 27, *) {
            return CoreAISpeechGraphExecutor(directory: directory)
        }
        #endif
        return nil
    }

    private func specialized(_ url: URL) -> Bool {
        if let isSpecialized { return isSpecialized(url) }
        #if canImport(CoreAI)
        if #available(iOS 27, macOS 27, *) {
            return (try? AIModelCache.default.model(for: url, options: .default)) != nil
        }
        #endif
        return false
    }

    private func functionNames(_ url: URL, file: String) throws -> [String]? {
        if let assetFunctionNames { return try assetFunctionNames(url) }
        #if canImport(CoreAI)
        if #available(iOS 27, macOS 27, *) {
            guard AIModelAsset.isValid(at: url) else {
                throw NeuralSpeechRuntimeError(kind: .unavailable, message: "model asset invalid: \(file)")
            }
            return try AIModelAsset(contentsOf: url).summary(includingStatistics: false)?.functions.map(\.name)
        }
        #endif
        return nil
    }

    private func specializeFile(_ url: URL) async throws {
        if let specialize {
            try await specialize(url)
            return
        }
        #if canImport(CoreAI)
        if #available(iOS 27, macOS 27, *) {
            _ = try await AIModel.specialize(contentsOf: url, options: .default)
            return
        }
        #endif
        throw NeuralSpeechRuntimeError(kind: .unavailable, message: CoreAISupport.unavailableReason)
    }
}
