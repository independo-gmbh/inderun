import Combine
import SwiftUI
import IndeRunContracts
import IndeRunCore
import IndeRunSwift
import IndeRunAppleProviders

@MainActor
final class SmokeTestViewModel: ObservableObject {
    enum AvailabilityState {
        case unknown
        case available
        case unavailable
    }

    @Published var prompt = "Explain one practical benefit of on-device AI in a single sentence."
    @Published private(set) var availabilityState: AvailabilityState = .unknown
    @Published private(set) var availabilityMessage = "Checking whether the Apple on-device provider can run on this device."
    @Published private(set) var outputText: String?
    @Published private(set) var errorText: String?
    @Published private(set) var isRunning = false

    private let hostServices: HostServices
    private let provider: AppleFoundationModelsProvider
    private let inderun: IndeRun

    init() {
        let hostServices = DefaultHostServices.make()
        let provider = AppleFoundationModelsProvider()
        let registry: ProviderRegistry

        do {
            registry = try AppleProviderRegistryFactory.makeDefaultRegistry()
        } catch {
            fatalError("Failed to create Apple provider registry: \(error)")
        }

        self.hostServices = hostServices
        self.provider = provider
        self.inderun = IndeRun(registry: registry, hostServices: hostServices)
    }

    var availabilityTitle: String {
        switch availabilityState {
        case .unknown:
            return "Checking"
        case .available:
            return "Available"
        case .unavailable:
            return "Unavailable"
        }
    }

    var availabilityColor: Color {
        switch availabilityState {
        case .unknown:
            return .secondary
        case .available:
            return .green
        case .unavailable:
            return .red
        }
    }

    func refreshAvailability() async {
        let capabilities = await provider.capabilities(host: hostServices)
        if capabilities.available {
            availabilityState = .available
            availabilityMessage = "The Apple on-device provider reports that it can run on this device right now."
        } else {
            availabilityState = .unavailable
            availabilityMessage = "The Apple on-device provider is not currently available. Apple Intelligence, device eligibility, locale, or model readiness may be blocking execution."
        }
    }

    func runPrompt() async {
        isRunning = true
        outputText = nil
        errorText = nil
        defer { isRunning = false }

        let request = TaskRequest(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            policy: Policy(execution: .onDevice)
        )

        do {
            let result = try await inderun.run(request: request)
            availabilityState = .available
            availabilityMessage = "The Apple on-device provider completed the request."
            outputText = result.output.text
        } catch let error as IndeRunException {
            if error.errorClass == .CapabilityMismatch {
                availabilityState = .unavailable
                availabilityMessage = "The provider rejected on-device execution for the current device or system state."
            }
            errorText = "\(error.errorClass.rawValue): \(error.message)"
        } catch {
            errorText = "UnexpectedError: \(error.localizedDescription)"
        }
    }
}
