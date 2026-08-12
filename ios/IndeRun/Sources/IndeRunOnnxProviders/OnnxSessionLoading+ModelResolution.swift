import CryptoKit
import Foundation
import IndeRunContracts

extension LoadedSessionBox {
    /// Verifies `ModelPackage.integrity.checksums` (`sha256:<hex>`) for every declared file this
    /// runtime actually resolved a path for, before the graph or tokenizer is loaded. Declared
    /// checksums for files outside this runtime's resolution (for example files a different
    /// runtime seam would use) are not checked -- only files under `directory` are addressable.
    static func verifyChecksums(_ modelPackage: ModelPackage, directory: URL) throws {
        guard let checksums = modelPackage.integrity?.checksums, !checksums.isEmpty else { return }

        for (fileName, expected) in checksums {
            let fileURL = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let parts = expected.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == "sha256" else {
                throw OnnxRuntimeError(
                    kind: .capability,
                    message: "checksum/integrity mismatch: unsupported algorithm for '\(fileName)' (only 'sha256:<hex>' is supported)."
                )
            }
            let expectedHex = String(parts[1])

            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw OnnxRuntimeError(
                    kind: .capability,
                    message: "model files missing: unable to read '\(fileName)' for checksum verification.",
                    originalError: error
                )
            }
            let actualHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

            guard actualHex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
                throw OnnxRuntimeError(
                    kind: .capability,
                    message: "checksum/integrity mismatch: '\(fileName)' does not match its declared checksum."
                )
            }
        }
    }

    static func resolveDirectory(_ modelPackage: ModelPackage) throws -> URL {
        guard let source = modelPackage.source else {
            throw OnnxRuntimeError(kind: .capability, message: "model source unavailable: model package declares no source.")
        }

        switch source.sourceType {
        case .bundled:
            guard let resourceURL = Bundle.main.resourceURL else {
                throw OnnxRuntimeError(kind: .unavailable, message: "runtime initialization failed: app bundle has no resource directory.")
            }
            return source.ref.map { resourceURL.appendingPathComponent($0) } ?? resourceURL
        case .filesystem:
            guard let ref = source.ref else {
                throw OnnxRuntimeError(kind: .capability, message: "model source unavailable: 'filesystem' source requires 'ref'.")
            }
            return URL(fileURLWithPath: ref)
        case .appManaged:
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            return source.ref.map { base.appendingPathComponent($0) } ?? base
        case .programmatic:
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model source unavailable: 'programmatic' sources require an application-supplied OnnxGenAiRuntime."
            )
        case .registry, .remote:
            throw OnnxRuntimeError(
                kind: .capability,
                message: "model source unavailable: '\(source.sourceType.rawValue)' model sources are deferred on Apple platforms."
            )
        }
    }
}
