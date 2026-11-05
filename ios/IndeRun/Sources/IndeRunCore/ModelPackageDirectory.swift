import CryptoKit
import Foundation
import IndeRunContracts

/// A failure resolving or verifying a model package directory.
public struct ModelPackageDirectoryError: Error, Sendable {
    public enum Kind: Sendable {
        /// The package cannot be used on this platform as declared.
        case capability
        /// The package may be usable, but the environment cannot provide it right now.
        case unavailable
    }

    public let kind: Kind
    public let message: String
    public let originalErrorDescription: String?

    public init(kind: Kind, message: String, originalError: Error? = nil) {
        self.kind = kind
        self.message = message
        self.originalErrorDescription = originalError.map { String(describing: $0) }
    }
}

/// Resolves a `ModelPackage` to a local directory and verifies its declared checksums. Shared by
/// every runtime that reads model files from disk.
public enum ModelPackageDirectory {
    /// `bundled` resolves under the main bundle's resources, `filesystem` is the path itself and
    /// `app_managed` sits under Application Support. Other source types are refused.
    public static func resolve(_ modelPackage: ModelPackage) throws -> URL {
        guard let source = modelPackage.source else {
            throw ModelPackageDirectoryError(kind: .capability, message: "model source unavailable: model package declares no source.")
        }

        switch source.sourceType {
        case .bundled:
            guard let resourceURL = Bundle.main.resourceURL else {
                throw ModelPackageDirectoryError(
                    kind: .unavailable, message: "runtime initialization failed: app bundle has no resource directory."
                )
            }
            return source.ref.map { resourceURL.appendingPathComponent($0) } ?? resourceURL
        case .filesystem:
            guard let ref = source.ref else {
                throw ModelPackageDirectoryError(
                    kind: .capability, message: "model source unavailable: 'filesystem' source requires 'ref'."
                )
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
            throw ModelPackageDirectoryError(
                kind: .capability,
                message: "model source unavailable: 'programmatic' sources are resolved by the application."
            )
        case .registry, .remote:
            throw ModelPackageDirectoryError(
                kind: .capability,
                message: "model source unavailable: '\(source.sourceType.rawValue)' model sources are deferred on Apple platforms."
            )
        }
    }

    /// Verifies `integrity.checksums` (`sha256:<hex>`) for every declared file that exists under
    /// `directory`; declared files that are not present are not checked.
    public static func verifyChecksums(_ modelPackage: ModelPackage, directory: URL) throws {
        guard let checksums = modelPackage.integrity?.checksums, !checksums.isEmpty else { return }

        for (fileName, expected) in checksums {
            let fileURL = directory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let parts = expected.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == "sha256" else {
                throw ModelPackageDirectoryError(
                    kind: .capability,
                    message: "checksum/integrity mismatch: unsupported algorithm for '\(fileName)' (only 'sha256:<hex>' is supported)."
                )
            }
            let expectedHex = String(parts[1])

            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw ModelPackageDirectoryError(
                    kind: .capability,
                    message: "model files missing: unable to read '\(fileName)' for checksum verification.",
                    originalError: error
                )
            }
            let actualHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

            guard actualHex.caseInsensitiveCompare(expectedHex) == .orderedSame else {
                throw ModelPackageDirectoryError(
                    kind: .capability,
                    message: "checksum/integrity mismatch: '\(fileName)' does not match its declared checksum."
                )
            }
        }
    }
}
