import CryptoKit
import Foundation
import IndeRunContracts
import XCTest
@testable import IndeRunCore
@testable import IndeRunOnnxProviders

final class ModelPackageDirectoryTests: XCTestCase {
    private func package(source: Source?, checksums: [String: String]? = nil) -> ModelPackage {
        ModelPackage(
            files: nil,
            format: .onnx,
            id: "test-model",
            integrity: checksums.map { Integrity(checksums: $0) },
            license: nil,
            limits: nil,
            runtime: nil,
            source: source,
            speech: nil,
            tasks: ["text_to_speech"],
            variant: nil,
            version: "1.0"
        )
    }

    private func makeDirectory(file: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(file))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func assertCapability(_ body: () throws -> Void, contains text: String, line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line) { error in
            guard let error = error as? ModelPackageDirectoryError else { return XCTFail("wrong error \(error)", line: line) }
            XCTAssertEqual(error.kind, .capability, line: line)
            XCTAssertTrue(error.message.contains(text), error.message, line: line)
        }
    }

    func testFilesystemRefResolves() throws {
        let url = try ModelPackageDirectory.resolve(package(source: Source(ref: "/tmp/some-model", sourceType: .filesystem)))
        XCTAssertEqual(url.path, "/tmp/some-model")
    }

    func testBundledResolvesUnderTheMainBundleResources() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let url = try ModelPackageDirectory.resolve(package(source: Source(ref: "models/a", sourceType: .bundled)))
        XCTAssertEqual(url, resources.appendingPathComponent("models/a"))
        XCTAssertEqual(try ModelPackageDirectory.resolve(package(source: Source(ref: nil, sourceType: .bundled))), resources)
    }

    func testAppManagedResolvesUnderApplicationSupport() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let url = try ModelPackageDirectory.resolve(package(source: Source(ref: "models/a", sourceType: .appManaged)))
        XCTAssertEqual(url, base.appendingPathComponent("models/a"))
        XCTAssertEqual(try ModelPackageDirectory.resolve(package(source: Source(ref: nil, sourceType: .appManaged))), base)
    }

    func testMissingSourceIsCapability() {
        assertCapability({ _ = try ModelPackageDirectory.resolve(self.package(source: nil)) }, contains: "model package declares no source")
    }

    func testProgrammaticIsCapability() {
        assertCapability(
            { _ = try ModelPackageDirectory.resolve(self.package(source: Source(ref: nil, sourceType: .programmatic))) },
            contains: "'programmatic' sources are resolved by the application."
        )
    }

    func testTheOnnxWrapperNamesTheApplicationRuntimeForProgrammaticSources() {
        XCTAssertThrowsError(
            try LoadedSessionBox.resolveDirectory(package(source: Source(ref: nil, sourceType: .programmatic)))
        ) { error in
            let error = error as? OnnxRuntimeError
            XCTAssertEqual(error?.kind, .capability)
            XCTAssertEqual(
                error?.message,
                "model source unavailable: 'programmatic' sources require an application-supplied OnnxGenAiRuntime."
            )
        }
    }

    func testRegistryAndRemoteAreDeferred() {
        for type in [SourceType.registry, .remote] {
            assertCapability(
                { _ = try ModelPackageDirectory.resolve(self.package(source: Source(ref: "x", sourceType: type))) },
                contains: "deferred on Apple platforms"
            )
        }
    }

    func testChecksumMatchPasses() throws {
        let data = Data("hello".utf8)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = try makeDirectory(file: "a.bin", contents: data)
        XCTAssertNoThrow(try ModelPackageDirectory.verifyChecksums(
            package(source: nil, checksums: ["a.bin": "sha256:\(hex)"]), directory: directory
        ))
    }

    func testChecksumMismatchIsCapability() throws {
        let directory = try makeDirectory(file: "a.bin", contents: Data("hello".utf8))
        assertCapability({
            try ModelPackageDirectory.verifyChecksums(
                self.package(source: nil, checksums: ["a.bin": "sha256:00"]), directory: directory
            )
        }, contains: "does not match its declared checksum")
    }

    func testUnsupportedAlgorithmIsCapability() throws {
        let directory = try makeDirectory(file: "a.bin", contents: Data("hello".utf8))
        assertCapability({
            try ModelPackageDirectory.verifyChecksums(
                self.package(source: nil, checksums: ["a.bin": "md5:00"]), directory: directory
            )
        }, contains: "unsupported algorithm")
    }

    func testAnUnreadableDeclaredFileIsCapability() throws {
        let directory = try makeDirectory(file: "a.bin", contents: Data())
        // A directory under the declared name exists but cannot be read as data.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("b.bin"), withIntermediateDirectories: false)
        assertCapability({
            try ModelPackageDirectory.verifyChecksums(
                self.package(source: nil, checksums: ["b.bin": "sha256:00"]), directory: directory
            )
        }, contains: "unable to read 'b.bin' for checksum verification")
    }

    func testMissingDeclaredFileIsSkipped() throws {
        let directory = try makeDirectory(file: "a.bin", contents: Data())
        XCTAssertNoThrow(try ModelPackageDirectory.verifyChecksums(
            package(source: nil, checksums: ["gone.bin": "sha256:00"]), directory: directory
        ))
    }
}
