import Foundation
import XCTest
import IndeRunContracts
@testable import IndeRunCore
@testable import IndeRunCoreAIProviders

/// The composed Core AI runtime's checks, readiness and consent rule, driven through its test hooks
/// so no model and no Core AI are needed: these run on every build, the stub build included.
final class CoreAINeuralSpeechRuntimeTests: XCTestCase {
    private let host = HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Refusals

    func testUnavailableCoreAIRefusesWithTheReasonEverywhere() async throws {
        let runtime = CoreAINeuralSpeechRuntime()
        runtime.isAvailableOverride = false
        let package = try makePackage(directory: try makeDirectory())
        for availability in [await runtime.availability(package), await runtime.prepare(package)] {
            XCTAssertFalse(availability.available)
            XCTAssertEqual(availability.reason, CoreAISupport.unavailableReason)
            XCTAssertNil(availability.readiness)
        }
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "Hallo.", locale: "de-DE", voiceId: "v")
        do {
            for try await _ in runtime.synthesize(input) {}
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertEqual(error.message, CoreAISupport.unavailableReason)
        }
    }

    func testAnOnnxPackageIsAnUnsupportedFormat() async throws {
        let runtime = makeRuntime()
        let package = try makePackage(directory: try makeDirectory(), format: "onnx")
        let availability = await runtime.availability(package)
        XCTAssertFalse(availability.available)
        XCTAssertEqual(availability.reason, "unsupported format 'onnx'")
    }

    func testAnotherPipelineIsUnsupported() async throws {
        let runtime = makeRuntime()
        let package = try makePackage(directory: try makeDirectory(), pipeline: "kokoro")
        for availability in [await runtime.availability(package), await runtime.prepare(package)] {
            XCTAssertFalse(availability.available)
            XCTAssertEqual(availability.reason, "unsupported pipeline 'kokoro'")
        }
    }

    func testAMissingGraphFileIsReported() async throws {
        let runtime = makeRuntime()
        let package = try makePackage(directory: try makeDirectory(files: ["text.aimodel", "decoder.aimodel"]))
        for availability in [await runtime.availability(package), await runtime.prepare(package)] {
            XCTAssertFalse(availability.available)
            XCTAssertEqual(availability.reason, "model files missing: dit_step.aimodel")
        }
    }

    func testAMalformedGraphReferenceIsReportedVerbatim() async throws {
        let runtime = makeRuntime()
        let graphs = #"{"text":"text.aimodel#a#b","dit_step":"dit_step.aimodel#dit_step","decoder":"decoder.aimodel"}"#
        let package = try makePackage(directory: try makeDirectory(), graphs: graphs)
        let availability = await runtime.availability(package)
        XCTAssertFalse(availability.available)
        XCTAssertEqual(availability.reason, "graph reference invalid: text: text.aimodel#a#b")
    }

    func testAGraphFileOutsideThePackageIsRefused() async throws {
        let runtime = makeRuntime()
        let graphs = #"{"text":"../text.aimodel","dit_step":"dit_step.aimodel#dit_step","decoder":"decoder.aimodel"}"#
        let package = try makePackage(directory: try makeDirectory(), graphs: graphs)
        let availability = await runtime.availability(package)
        XCTAssertFalse(availability.available)
        XCTAssertEqual(availability.reason, "model file name invalid: ../text.aimodel")
    }

    func testAPackageLargerThanTheDeviceIsRefused() async throws {
        let runtime = makeRuntime(options: CoreAINeuralSpeechRuntimeOptions(deviceMemoryBytes: { 1000 }))
        let package = try makePackage(directory: try makeDirectory(), limits: #"{"memBytes":2000}"#)
        for availability in [await runtime.availability(package), await runtime.prepare(package)] {
            XCTAssertFalse(availability.available)
            XCTAssertEqual(availability.reason, "insufficient memory: package needs 2000 bytes, device has 1000 bytes")
        }
    }

    func testSynthesizeBeforePrepareIsRefused() async throws {
        let runtime = makeRuntime()
        let package = try makePackage(directory: try makeDirectory())
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "Hallo.", locale: "de-DE", voiceId: "v")
        do {
            for try await _ in runtime.synthesize(input) {}
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertEqual(error.message, "model not prepared: coreai-fixture@1")
        }
    }

    func testAPackageWithoutADecoderGraphIsRefusedBeforeSpecialization() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
        let graphs = #"{"text":"text.aimodel","dit_step":"dit_step.aimodel#dit_step"}"#
        let package = try makePackage(directory: try makeDirectory(), graphs: graphs)
        for availability in [await runtime.availability(package), await runtime.prepare(package)] {
            XCTAssertEqual(availability, NeuralSpeechAvailability(available: false, reason: "graph missing: decoder"))
        }
        XCTAssertEqual(cache.calls, 0)
    }

    func testAPackageWithoutAPipelineConfigIsRefusedBeforeSpecialization() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
        let package = try makePackage(directory: try makeDirectory(), frontendAssets: "{}")
        for availability in [await runtime.availability(package), await runtime.prepare(package)] {
            XCTAssertEqual(
                availability,
                NeuralSpeechAvailability(available: false, reason: "pipeline config missing: speech.frontend.assets.config")
            )
        }
        XCTAssertEqual(cache.calls, 0)
    }

    func testAMissingConfigOrVoiceFileIsRefusedBeforeSpecialization() async throws {
        for (assets, missing) in [(["voices/v.safetensors"], "config.json"), (["config.json"], "voices/v.safetensors")] {
            let cache = SpecializationCache()
            let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
            let package = try makePackage(directory: try makeDirectory(assets: assets))
            for availability in [await runtime.availability(package), await runtime.prepare(package)] {
                XCTAssertEqual(availability, NeuralSpeechAvailability(available: false, reason: "model files missing: \(missing)"))
            }
            XCTAssertEqual(cache.calls, 0, missing)
        }
    }

    // MARK: - Readiness and consent

    func testUnspecializedFilesReportNotPrepared() async throws {
        let runtime = makeRuntime(isSpecialized: { _ in false })
        let availability = await runtime.availability(try makePackage(directory: try makeDirectory()))
        XCTAssertEqual(availability, NeuralSpeechAvailability(available: true, readiness: .notPrepared))
    }

    func testSpecializedFilesReportCold() async throws {
        let runtime = makeRuntime(isSpecialized: { _ in true })
        let availability = await runtime.availability(try makePackage(directory: try makeDirectory()))
        XCTAssertEqual(availability, NeuralSpeechAvailability(available: true, readiness: .cold))
    }

    func testAvailabilityNeverSpecializes() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
        _ = await runtime.availability(try makePackage(directory: try makeDirectory()))
        XCTAssertEqual(cache.calls, 0)
    }

    func testPrepareTwiceSpecializesOnce() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
        // Graph files but no config.json: specialization runs, the pipeline step then fails.
        let package = try makePackage(directory: try makeDirectory())
        let first = await runtime.prepare(package)
        let second = await runtime.prepare(package)
        XCTAssertFalse(first.available)
        XCTAssertFalse(second.available)
        // Three distinct files, each specialized on the first prepare only.
        XCTAssertEqual(cache.calls, 3)
        XCTAssertEqual(cache.specialized.count, 3)
    }

    func testRolesSharingAFileSpecializeItOnce() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
        let graphs = #"{"text":"speech.aimodel#text","dit_step":"speech.aimodel#dit_step","decoder":"speech.aimodel#decoder"}"#
        let package = try makePackage(directory: try makeDirectory(files: ["speech.aimodel"]), graphs: graphs)
        _ = await runtime.prepare(package)
        XCTAssertEqual(cache.calls, 1)
    }

    func testASpecializationFailureIsReported() async throws {
        let runtime = makeRuntime(isSpecialized: { _ in false }, specialize: { _ in
            throw NeuralSpeechRuntimeError(kind: .unavailable, message: "no space left")
        })
        let prepared = await runtime.prepare(try makePackage(directory: try makeDirectory()))
        XCTAssertFalse(prepared.available)
        XCTAssertEqual(prepared.reason, "specialization failed: decoder.aimodel: no space left")
    }

    // MARK: - Asset function check

    private let sharedGraphs =
        #"{"text":"articulino.aimodel#text","dit_step":"articulino.aimodel#dit_step","decoder":"articulino.aimodel#decoder"}"#

    func testAMissingAssetFunctionIsRefusedBeforeSpecialization() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize, assetFunctionNames: { _ in ["text", "dit_step"] })
        let package = try makePackage(directory: try makeDirectory(files: ["articulino.aimodel"]), graphs: sharedGraphs)
        let prepared = await runtime.prepare(package)
        XCTAssertEqual(
            prepared, NeuralSpeechAvailability(available: false, reason: "graph function missing: decoder: decoder in articulino.aimodel")
        )
        XCTAssertEqual(cache.calls, 0)
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "Hallo.", locale: "de-DE", voiceId: "v")
        do {
            for try await _ in runtime.synthesize(input) {}
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(
                error.message, "model not prepared: coreai-fixture@1: graph function missing: decoder: decoder in articulino.aimodel"
            )
        }
    }

    func testAnAssetWithoutASummarySkipsTheFunctionCheck() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize, assetFunctionNames: { _ in nil })
        let package = try makePackage(directory: try makeDirectory(files: ["articulino.aimodel"]), graphs: sharedGraphs)
        _ = await runtime.prepare(package)
        XCTAssertEqual(cache.calls, 1)
    }

    func testAnAssetFunctionCheckFailureIsReported() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize, assetFunctionNames: { _ in
            throw NeuralSpeechRuntimeError(kind: .unavailable, message: "model asset invalid: articulino.aimodel")
        })
        let package = try makePackage(directory: try makeDirectory(files: ["articulino.aimodel"]), graphs: sharedGraphs)
        let prepared = await runtime.prepare(package)
        XCTAssertEqual(prepared, NeuralSpeechAvailability(available: false, reason: "model asset invalid: articulino.aimodel"))
        XCTAssertEqual(cache.calls, 0)
    }

    func testConcurrentPreparesSpecializeEachFileOnce() async throws {
        let cache = SpecializationCache(delayNanoseconds: 50_000_000)
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
        let package = try makePackage(directory: try makeDirectory())
        async let first = runtime.prepare(package)
        async let second = runtime.prepare(package)
        _ = await (first, second)
        XCTAssertEqual(cache.calls, 3)
    }

    func testSynthesizeAfterAFailedPrepareReportsTheFailure() async throws {
        let runtime = makeRuntime(isSpecialized: { _ in false }, specialize: { _ in
            throw NeuralSpeechRuntimeError(kind: .unavailable, message: "no space left")
        })
        let package = try makePackage(directory: try makeDirectory())
        _ = await runtime.prepare(package)
        let input = NeuralSpeechSynthesisInput(modelPackage: package, text: "Hallo.", locale: "de-DE", voiceId: "v")
        do {
            for try await _ in runtime.synthesize(input) {}
            XCTFail("expected a failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .unavailable)
            XCTAssertEqual(
                error.message, "model not prepared: coreai-fixture@1: specialization failed: decoder.aimodel: no space left"
            )
        }
    }

    func testAvailabilityIsColdWithoutProbingTheCacheOncePrepared() async throws {
        let cache = SpecializationCache()
        let runtime = makeRuntime(isSpecialized: cache.contains, specialize: cache.specialize)
        let package = try makePackage(directory: try makeDirectory())
        await runtime.markPrepared(package)
        let availability = await runtime.availability(package)
        XCTAssertEqual(availability, NeuralSpeechAvailability(available: true, readiness: .cold))
        XCTAssertEqual(cache.lookups, 0)
    }

    // MARK: - Provider factory

    func testTheFactoryDefaultsTheIdAndDescribesThePackageModel() throws {
        let package = try makePackage(directory: try makeDirectory())
        let provider = makeCoreAINeuralSpeechProvider(options: CoreAINeuralSpeechProviderOptions(modelPackage: package))
        XCTAssertEqual(NeuralSpeechProvider.coreAIDefaultId, "local.coreai.speech.apple")
        XCTAssertEqual(provider.id, "local.coreai.speech.apple:coreai-fixture")
        XCTAssertEqual(provider.describe().model, "coreai-fixture")
        let named = makeCoreAINeuralSpeechProvider(options: CoreAINeuralSpeechProviderOptions(id: "speech", modelPackage: package))
        XCTAssertEqual(named.id, "speech")
    }

    func testAProviderOverAnUnavailableRuntimeIsUnavailableWithTheReason() async throws {
        let package = try makePackage(directory: try makeDirectory())
        let runtime = CoreAINeuralSpeechRuntime()
        runtime.isAvailableOverride = false
        let provider = NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: package, runtime: runtime))
        let capabilities = await provider.capabilities(host: host)
        XCTAssertFalse(capabilities.available)
        XCTAssertEqual(capabilities.reason, CoreAISupport.unavailableReason)
        XCTAssertNil(capabilities.taskCapabilities?.first?.readiness)
    }

    func testTheFactoryProviderReportsThisDevice() async throws {
        let package = try makePackage(directory: try makeDirectory())
        let provider = makeCoreAINeuralSpeechProvider(options: CoreAINeuralSpeechProviderOptions(modelPackage: package))
        let capabilities = await provider.capabilities(host: host)
        if CoreAISupport.isAvailable {
            // The empty graph files are not in the specialization cache.
            XCTAssertTrue(capabilities.available, capabilities.reason ?? "")
            XCTAssertEqual(capabilities.taskCapabilities?.first?.readiness, .notPrepared)
        } else {
            XCTAssertFalse(capabilities.available)
            XCTAssertEqual(capabilities.reason, CoreAISupport.unavailableReason)
            XCTAssertNil(capabilities.taskCapabilities?.first?.readiness)
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        options: CoreAINeuralSpeechRuntimeOptions = .init(),
        isSpecialized: ((URL) -> Bool)? = { _ in false },
        specialize: ((URL) async throws -> Void)? = { _ in },
        assetFunctionNames: ((URL) throws -> [String]?)? = { _ in nil }
    ) -> CoreAINeuralSpeechRuntime {
        let runtime = CoreAINeuralSpeechRuntime(options: options)
        runtime.isAvailableOverride = true
        runtime.isSpecialized = isSpecialized
        runtime.specialize = specialize
        runtime.assetFunctionNames = assetFunctionNames
        return runtime
    }

    /// A temp package directory holding empty graph, config and voice files: the pipeline step fails
    /// on the empty `config.json`, after specialization.
    private func makeDirectory(
        files: [String] = ["text.aimodel", "dit_step.aimodel", "decoder.aimodel"],
        assets: [String] = ["config.json", "voices/v.safetensors"]
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("voices"), withIntermediateDirectories: true)
        directories.append(directory)
        for file in files + assets {
            XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent(file).path, contents: Data()))
        }
        return directory
    }

    private func makePackage(
        directory: URL,
        format: String = "coreai",
        pipeline: String = "articulino",
        graphs: String = #"{"text":"text.aimodel","dit_step":"dit_step.aimodel#dit_step","decoder":"decoder.aimodel"}"#,
        limits: String = "null",
        frontendAssets: String = #"{"config":"config.json"}"#
    ) throws -> ModelPackage {
        let source = #"{"sourceType":"filesystem","ref":"\#(directory.path)"}"#
        let json = """
        {"id":"coreai-fixture","version":"1","format":"\(format)","tasks":["text_to_speech"],"source":\(source),"limits":\(limits),
         "speech":{"pipeline":"\(pipeline)","sampleRate":24000,"channels":1,"graphs":\(graphs),
          "frontend":{"kind":"grapheme","assets":\(frontendAssets)},
          "voices":[{"id":"v","name":"V","locales":["de-DE"],"file":"voices/v.safetensors"}]}}
        """
        return try JSONDecoder().decode(ModelPackage.self, from: Data(json.utf8))
    }
}

/// Test double of `AIModelCache`: `specialize` inserts (after `delayNanoseconds`), `contains` looks up.
private final class SpecializationCache: @unchecked Sendable {
    private let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var urls: Set<URL> = []
    private var count = 0
    private var lookupCount = 0

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    var calls: Int { lock.withLock { count } }
    var lookups: Int { lock.withLock { lookupCount } }
    var specialized: Set<URL> { lock.withLock { urls } }

    func contains(_ url: URL) -> Bool {
        lock.withLock {
            lookupCount += 1
            return urls.contains(url.standardizedFileURL)
        }
    }

    func specialize(_ url: URL) async throws {
        lock.withLock { count += 1 }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        lock.withLock { _ = urls.insert(url.standardizedFileURL) }
    }
}
