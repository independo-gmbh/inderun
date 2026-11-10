import Foundation

/// One `speech.graphs` value of a `coreai` package: the `.aimodel` file and the inference function
/// in it. `<file>` names the function after the role; `<file>#<function>` names it explicitly, so
/// several roles can share one file. The file name is checked against the package directory by the
/// executor (``checkPackageFileName(_:)``), not here.
public struct CoreAIGraphReference: Equatable, Sendable {
    public let file: String
    public let function: String

    /// Throws `graph reference invalid: <role>: <value>` (capability) for an empty file or function
    /// part, or a second `#`.
    public init(role: String, value: String) throws {
        let parts = value.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        let invalid = NeuralSpeechRuntimeError(kind: .capability, message: "graph reference invalid: \(role): \(value)")
        switch parts.count {
        case 1:
            file = parts[0]
            function = role
        case 2:
            file = parts[0]
            function = parts[1]
        default:
            throw invalid
        }
        if file.isEmpty || function.isEmpty {
            throw invalid
        }
    }
}
