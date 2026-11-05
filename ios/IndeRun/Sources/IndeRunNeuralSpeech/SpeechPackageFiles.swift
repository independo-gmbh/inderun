import Foundation

/// Reads the files of a speech model package (graphs aside: configs, voices, frontend assets) by
/// their package-relative names. Platform-neutral so a pipeline runs over a directory, an app
/// bundle or memory alike.
public protocol SpeechPackageFiles: Sendable {
    func read(_ file: String) async throws -> Data
}

/// Throws `model file name invalid: <file>` (capability) for a name a package file may not have:
/// empty, absolute, or with a `..` component, so a package cannot reach outside its directory. Every
/// package file reader and graph executor applies it.
package func checkPackageFileName(_ file: String) throws {
    let components = file.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
    if file.isEmpty || file.hasPrefix("/") || file.hasPrefix("\\") || components.contains("..") {
        throw NeuralSpeechRuntimeError(kind: .capability, message: "model file name invalid: \(file)")
    }
}

/// ``SpeechPackageFiles`` over a directory on disk. Names that are empty, absolute or contain a `..`
/// component are refused (``checkPackageFileName(_:)``), so a package cannot read outside its directory.
public struct DirectoryPackageFiles: SpeechPackageFiles {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func read(_ file: String) async throws -> Data {
        try checkPackageFileName(file)
        do {
            return try Data(contentsOf: directory.appendingPathComponent(file))
        } catch {
            throw NeuralSpeechRuntimeError(kind: .capability, message: "model files missing: \(file)", originalError: error)
        }
    }
}
