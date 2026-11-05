import Foundation
import IndeRunContracts
import IndeRunCore

extension LoadedSessionBox {
    /// Verifies `ModelPackage.integrity.checksums` before the graph or tokenizer is loaded; see
    /// `ModelPackageDirectory.verifyChecksums`.
    static func verifyChecksums(_ modelPackage: ModelPackage, directory: URL) throws {
        do {
            try ModelPackageDirectory.verifyChecksums(modelPackage, directory: directory)
        } catch let error as ModelPackageDirectoryError {
            throw runtimeError(error)
        }
    }

    static func resolveDirectory(_ modelPackage: ModelPackage) throws -> URL {
        do {
            return try ModelPackageDirectory.resolve(modelPackage)
        } catch let error as ModelPackageDirectoryError {
            // The shared resolver refuses `programmatic` generically; ONNX Runtime names the
            // application-supplied runtime that serves such a package instead.
            if modelPackage.source?.sourceType == .programmatic {
                throw OnnxRuntimeError(
                    kind: .capability,
                    message: "model source unavailable: 'programmatic' sources require an application-supplied OnnxGenAiRuntime."
                )
            }
            throw runtimeError(error)
        }
    }

    private static func runtimeError(_ error: ModelPackageDirectoryError) -> OnnxRuntimeError {
        OnnxRuntimeError(
            kind: error.kind == .capability ? .capability : .unavailable,
            message: error.message,
            originalError: error.originalErrorDescription.map(OriginalErrorDescription.init)
        )
    }
}

/// Carries an already-rendered error description through `OnnxRuntimeError.originalError`.
private struct OriginalErrorDescription: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }
}
