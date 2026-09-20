import XCTest
import IndeRunOpenAIProviders

// Second consumer-compilation smoke test, for a provider product rather than the
// umbrella one. Same rule as IndeRunUmbrellaConsumerTests: this target depends on
// `IndeRunOpenAIProviders` and nothing else.
//
// An app that registers a provider manually reaches `ProviderRegistry` and
// `ProviderAdapter` from IndeRunCore and `TaskRequest` from IndeRunContracts
// without ever naming those modules, so the provider targets have to re-export
// IndeRunCore too -- not just IndeRunSwift.
//
// Do not add dependencies or imports to this target.
final class ProviderConsumerSmokeTests: XCTestCase {
    func testCoreAndContractTypesAreReachableThroughAProviderProduct() throws {
        let provider = OpenAIProvider(
            options: OpenAIProviderOptions(
                model: "gpt-5.2",
                endpointURL: defaultOpenAIResponsesEndpoint,
                authContextRef: "openai_primary"
            )
        )

        // ProviderRegistry and ProviderAdapter come from IndeRunCore.
        let registry = ProviderRegistry()
        try registry.register(provider)
        let adapters: [any ProviderAdapter] = registry.list()
        XCTAssertEqual(adapters.count, 1)

        // TaskRequest comes from IndeRunContracts.
        let request = TaskRequest(prompt: "Hello")
        XCTAssertEqual(request.prompt, "Hello")
    }
}
