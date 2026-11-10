import Foundation
import IndeRunContracts
import IndeRunNeuralSpeech

public extension NeuralSpeechProvider {
    /// The id prefix of a provider made by ``makeCoreAINeuralSpeechProvider(options:)``.
    static let coreAIDefaultId = "local.coreai.speech.apple"
}

/// Configuration for ``makeCoreAINeuralSpeechProvider(options:)``.
public struct CoreAINeuralSpeechProviderOptions: Sendable {
    /// Defaults to `"\(NeuralSpeechProvider.coreAIDefaultId):\(modelPackage.id)"`.
    public let id: String?
    /// A `format: "coreai"` speech model package.
    public let modelPackage: ModelPackage
    /// As ``NeuralSpeechProviderOptions/timeout``.
    public let timeout: Duration?
    public let runtime: CoreAINeuralSpeechRuntimeOptions

    public init(
        id: String? = nil,
        modelPackage: ModelPackage,
        timeout: Duration? = nil,
        runtime: CoreAINeuralSpeechRuntimeOptions = .init()
    ) {
        self.id = id
        self.modelPackage = modelPackage
        self.timeout = timeout
        self.runtime = runtime
    }
}

/// A ``NeuralSpeechProvider`` that runs a `coreai` package through a ``CoreAINeuralSpeechRuntime``.
/// Specializing the asset needs the app's consent: register with `autoDownload` or call
/// `prepare({ allowDownload: true })`, otherwise a device whose specialization cache is empty is skipped.
///
/// The factory builds the runtime, so the returned provider owns it: the application releases the
/// loaded models with the provider's `close()` once no engine routes to it any more (engine
/// `close()` does not close providers the application registered).
public func makeCoreAINeuralSpeechProvider(options: CoreAINeuralSpeechProviderOptions) -> NeuralSpeechProvider {
    NeuralSpeechProvider(
        options: NeuralSpeechProviderOptions(
            id: options.id ?? "\(NeuralSpeechProvider.coreAIDefaultId):\(options.modelPackage.id)",
            modelPackage: options.modelPackage,
            runtime: CoreAINeuralSpeechRuntime(options: options.runtime),
            timeout: options.timeout
        ),
        ownsRuntime: true
    )
}
