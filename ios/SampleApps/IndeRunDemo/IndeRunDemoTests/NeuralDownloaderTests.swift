import CryptoKit
import XCTest
@testable import IndeRunDemo

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    var requested: [String] { lock.withLock { urls } }
    func record(_ url: URL) { lock.withLock { urls.append(url.absoluteString) } }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func file(_ path: String, _ payload: Data, host: String = "https://example.com") -> CatalogFile {
    CatalogFile(role: nil, path: path, url: "\(host)/\(path)", sha256: sha256Hex(payload), bytes: Int64(payload.count))
}

private let weights = Data("weights-weights-weights".utf8)
private let config = Data("{\"config\":true}".utf8)
private let voice = Data("voice-bundle-bytes".utf8)

private func entry() -> CatalogEntry {
    let license = CatalogLicense(spdx: "Apache-2.0", url: nil, restrictions: "none", attribution: "Upstream attribution")
    return CatalogEntry(
        id: "test-entry", variant: "onnx-int8", version: "1", license: license,
        reviewStatus: "benchmark_only", reviewNotes: nil, runtimeFormat: "onnx", minOsVersion: nil,
        speechPipeline: "articulino", sampleRate: 24000, channels: 1,
        graphs: ["text": "text.onnx"], frontendKind: "grapheme", frontendAssets: ["config": "config.json"],
        files: [file("config.json", config), file("text.onnx", weights, host: "https://github.com/independo-gmbh/inderun/releases/download/neural-speech-assets-1")],
        voices: [CatalogVoice(
            id: "v1", name: "Voice 1", locales: ["de-DE"], gender: nil,
            file: file("voices/v1.safetensors", voice),
            license: CatalogLicense(spdx: "LicenseRef-Independo-Demo-Voices", url: nil, restrictions: "demo use only", attribution: nil)
        )]
    )
}

private let payloads: [String: Data] = [
    "config.json": config, "text.onnx": weights, "voices/v1.safetensors": voice,
]

private func payload(for url: URL) -> Data {
    payloads.first { url.absoluteString.hasSuffix($0.key) }?.value ?? Data()
}

/// A transport that answers from `payloads`, in two chunks, unless `handler` says otherwise.
private final class FakeTransport: NeuralTransport, @unchecked Sendable {
    let recorder = Recorder()
    var handler: @Sendable (URL) async throws -> NeuralTransportResponse = { url in
        let data = payload(for: url)
        let half = data.count / 2
        return NeuralTransportResponse(status: 200, finalURL: url, body: chunks([data.prefix(half), data.suffix(from: half)].map { Data($0) }))
    }

    func open(_ url: URL) async throws -> NeuralTransportResponse {
        recorder.record(url)
        return try await handler(url)
    }
}

private func chunks(_ parts: [Data], thenHang: Bool = false) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            for part in parts { continuation.yield(part) }
            if thenHang {
                try? await Task.sleep(for: .seconds(60))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private struct FailingSink: NeuralFileSink {
    func write(_ data: Data) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    }

    func close() throws {}
}

final class NeuralDownloaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voices-lab-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func downloader(_ transport: FakeTransport, sink: (@Sendable (URL) throws -> any NeuralFileSink)? = nil) -> DemoNeuralModelDownloader {
        DemoNeuralModelDownloader(root: root, transport: transport, makeSink: sink ?? { try FileHandleSink(url: $0) })
    }

    private func partFiles() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        return (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".part") }
    }

    func testDeclinedConsentMakesNoRequestAndCreatesNothing() async throws {
        let transport = FakeTransport()
        let result = try await downloader(transport).download(entry(), consent: { _ in false }, onProgress: { _, _ in })
        XCTAssertEqual(result, .declined)
        XCTAssertEqual(transport.recorder.requested, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testConsentShowsTheRealTotalAndEveryDistinctLicence() async throws {
        let prompts = PromptBox()
        _ = try await downloader(FakeTransport()).download(entry(), consent: { await prompts.set($0); return false }, onProgress: { _, _ in })
        let captured = await prompts.value
        let prompt = try XCTUnwrap(captured)
        XCTAssertEqual(prompt.totalBytes, Int64(config.count + weights.count + voice.count))
        XCTAssertEqual(prompt.licenses.count, 3)
        XCTAssertTrue(prompt.licenses[0].contains("Apache-2.0"))
        XCTAssertTrue(prompt.licenses.contains("Upstream attribution"))
        XCTAssertTrue(prompt.licenses.contains { $0.contains("LicenseRef-Independo-Demo-Voices") && $0.contains("demo use only") })
    }

    func testDownloadInstallsEveryFileAndLeavesNoPartFile() async throws {
        let subject = downloader(FakeTransport())
        let current = entry()
        let installedBefore = await subject.isInstalled(current)
        XCTAssertFalse(installedBefore)
        let result = try await subject.download(current, consent: { _ in true }, onProgress: { _, _ in })
        XCTAssertEqual(result, .installed)
        let installedAfter = await subject.isInstalled(current)
        XCTAssertTrue(installedAfter)
        XCTAssertEqual(try Data(contentsOf: subject.directory(for: current).appendingPathComponent("text.onnx")), weights)
        XCTAssertEqual(partFiles(), [])
    }

    func testIsInstalledIsReadOnly() async {
        let installed = await downloader(FakeTransport()).isInstalled(entry())
        XCTAssertFalse(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testResumeSkipsVerifiedFiles() async throws {
        let transport = FakeTransport()
        let subject = downloader(transport)
        let current = entry()
        let directory = subject.directory(for: current)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try config.write(to: directory.appendingPathComponent("config.json"))

        _ = try await subject.download(current, consent: { _ in true }, onProgress: { _, _ in })

        XCTAssertFalse(transport.recorder.requested.contains { $0.hasSuffix("config.json") })
        XCTAssertEqual(transport.recorder.requested.count, 2)
    }

    func testPartialFileIsNotAccepted() async throws {
        let transport = FakeTransport()
        let subject = downloader(transport)
        let current = entry()
        let directory = subject.directory(for: current)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try weights.prefix(5).write(to: directory.appendingPathComponent("text.onnx"))

        _ = try await subject.download(current, consent: { _ in true }, onProgress: { _, _ in })

        XCTAssertTrue(transport.recorder.requested.contains { $0.hasSuffix("text.onnx") })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("text.onnx")), weights)
    }

    func testATruncatedBodyIsRejectedAndRemoved() async throws {
        let transport = FakeTransport()
        transport.handler = { url in
            NeuralTransportResponse(status: 200, finalURL: url, body: chunks([payload(for: url).prefix(4)].map { Data($0) }))
        }
        await assertFails(downloader(transport), contains: "checksum mismatch: config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voices-lab/test-entry/1/config.json").path))
        XCTAssertEqual(partFiles(), [])
    }

    func testChecksumMismatchRemovesTheFile() async throws {
        let transport = FakeTransport()
        transport.handler = { url in
            // Right length, wrong bytes.
            NeuralTransportResponse(status: 200, finalURL: url, body: chunks([Data(repeating: 0x41, count: payload(for: url).count)]))
        }
        await assertFails(downloader(transport), contains: "checksum mismatch: config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("voices-lab/test-entry/1/config.json").path))
        XCTAssertEqual(partFiles(), [])
    }

    func testStorageErrorIsReportedAndThePartialRemoved() async throws {
        let transport = FakeTransport()
        await assertFails(downloader(transport, sink: { _ in FailingSink() }), contains: "not enough storage space")
        XCTAssertEqual(partFiles(), [])
    }

    func testCancelMidStreamLeavesNoPartFile() async throws {
        let transport = FakeTransport()
        let started = AsyncStream<Void>.makeStream()
        transport.handler = { url in
            NeuralTransportResponse(status: 200, finalURL: url, body: chunks([Data("x".utf8)], thenHang: true))
        }
        let subject = downloader(transport)
        let task = Task {
            try await subject.download(entry(), consent: { _ in true }, onProgress: { done, _ in
                if done > 0 { started.continuation.yield() }
            })
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled download must not finish")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(partFiles(), [])
    }

    func testANonHTTPSFinalURLIsRejected() async throws {
        let transport = FakeTransport()
        transport.handler = { url in
            NeuralTransportResponse(status: 200, finalURL: URL(string: "http://example.com/x")!, body: chunks([payload(for: url)]))
        }
        await assertFails(downloader(transport), contains: "https")
    }

    func testAnUnpublishedGitHubAssetSaysSo() async throws {
        let transport = FakeTransport()
        transport.handler = { url in
            if url.host == "github.com" { return NeuralTransportResponse(status: 404, finalURL: url, body: chunks([])) }
            return NeuralTransportResponse(status: 200, finalURL: url, body: chunks([payload(for: url)]))
        }
        await assertFails(downloader(transport), contains: "asset not published yet (HTTP 404): text.onnx")
    }

    private func assertFails(_ subject: DemoNeuralModelDownloader, contains text: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await subject.download(entry(), consent: { _ in true }, onProgress: { _, _ in })
            XCTFail("expected a failure", file: file, line: line)
        } catch let error as NeuralDownloadError {
            XCTAssertTrue(error.message.contains(text), "\(error.message) should contain \(text)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private actor PromptBox {
    var value: ConsentPrompt?
    func set(_ prompt: ConsentPrompt) { value = prompt }
}

final class MegabytesFormatTests: XCTestCase {
    func testWholeDecimalMegabytesRoundedHalfUp() {
        XCTAssertEqual(VoicesLabScreen.megabytes(113_011_812), "113 MB")
        XCTAssertEqual(VoicesLabScreen.megabytes(500_000), "1 MB")
        XCTAssertEqual(VoicesLabScreen.megabytes(499_999), "0 MB")
    }
}
