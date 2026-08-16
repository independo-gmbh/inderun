import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DemoViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introSection
                    cloudSettingsSection
                    onnxSettingsSection
                    privacySection
                    promptSection
                    actionSection
                    availabilitySection
                    resultSection
                    routingDecisionSection
                    limitationsSection
                }
                .padding(20)
            }
            .navigationTitle("IndeRun Demo")
            .task {
                await viewModel.ensureSelectedOnnxModelDownloaded()
                await viewModel.refreshAvailability()
            }
        }
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run the same text request through IndeRun's capability-based provider routing: Apple Foundation Models on-device, an ONNX Runtime local provider, or a cloud endpoint exposed through the demo proxy.")
                .font(.body)
            Text("IndeRun picks the provider automatically from your privacy preference and each provider's reported capabilities.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy Preference")
                .font(.headline)
            Picker("Privacy Preference", selection: $viewModel.privacy) {
                ForEach(DemoViewModel.PrivacyPreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var cloudSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud Settings")
                .font(.headline)
            TextField("Endpoint URL", text: $viewModel.cloudEndpointURL, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

            TextField("Model", text: $viewModel.cloudModel)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Text(viewModel.cloudSettingsHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var onnxSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ONNX Local Settings")
                .font(.headline)
            Picker("ONNX Model", selection: $viewModel.onnxModelSelection) {
                ForEach(DemoOnnxModelSelection.allCases) { selection in
                    Text(selection.title).tag(selection)
                }
            }
            .pickerStyle(.menu)

            if case .downloading(let progress) = viewModel.onnxDownloadState {
                ProgressView(value: progress)
            }

            Text(viewModel.onnxSettingsHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt")
                .font(.headline)
            TextEditor(text: $viewModel.prompt)
                .frame(minHeight: 160)
                .padding(10)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
                .autocorrectionDisabled()
        }
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await viewModel.refreshAvailability()
                }
            } label: {
                Text("Refresh Status")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isRunning)

            Button {
                Task {
                    await viewModel.runPrompt()
                }
            } label: {
                if viewModel.isRunning {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Run")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canRun)
        }
    }

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider Availability")
                .font(.headline)

            switch viewModel.capabilitiesState {
            case .loading:
                Text("Checking provider availability...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed:
                Text("Unable to check provider availability.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .ready(let badges):
                ForEach(badges) { badge in
                    availabilityCard(badge: badge)
                }
            }
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result")
                .font(.headline)

            if let result = viewModel.result {
                resultPanel(title: "Output", body: result.outputText, tint: .green)
                metadataPanel(metadata: result.metadata)
            } else if let errorState = viewModel.errorState {
                resultPanel(title: errorState.title, body: errorState.body, tint: .red)
                if let metadata = errorState.metadata {
                    metadataPanel(metadata: metadata)
                }
            } else {
                resultPanel(
                    title: "Idle",
                    body: "Run the prompt to capture generated text or a normalized IndeRun error.",
                    tint: .secondary
                )
            }
        }
    }

    private var routingDecisionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Routing Decision")
                .font(.headline)

            if let decision = viewModel.lastRouteDecision {
                VStack(alignment: .leading, spacing: 8) {
                    metadataRow(label: "Selected", value: decision.selectedProviderId ?? "none")
                    metadataRow(label: "Explanation", value: decision.explanation.isEmpty ? "n/a" : decision.explanation)
                    if !decision.rejectedProviderIds.isEmpty {
                        metadataRow(label: "Rejected", value: decision.rejectedProviderIds.joined(separator: ", "))
                    }
                    if !decision.fallbackProviderIds.isEmpty {
                        metadataRow(label: "Fallbacks", value: decision.fallbackProviderIds.joined(separator: ", "))
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
            } else {
                Text("No run yet. The routing decision appears after the first attempt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var limitationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Known Limitations")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("• The ONNX Local provider runs against a deterministic fixture runtime by default. Point it at a real bundled/app-managed ModelPackage to exercise actual on-device inference.")
                Text("• Apple availability depends on device class, OS version, locale, Apple Intelligence state, and model readiness.")
                Text("• The app never embeds cloud credentials. The demo proxy resolves upstream endpoint and auth server-side.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func availabilityCard(badge: DemoViewModel.ProviderBadge) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(badge.label)
                .font(.subheadline.weight(.semibold))
            Text(badge.available ? "Available" : "Unavailable")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(badge.available ? .green : .red)
            Text(badge.id)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            if let reason = badge.reason, !badge.available {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func resultPanel(title: String, body: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(body)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func metadataPanel(metadata: DemoViewModel.AttemptMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attempt Metadata")
                .font(.subheadline.weight(.semibold))
            metadataRow(label: "Run ID", value: metadata.runId)
            metadataRow(label: "Provider Used", value: metadata.providerUsed)
            metadataRow(label: "Total ms", value: metadata.totalMsDescription)
            if let providerId = metadata.providerId {
                metadataRow(label: "Provider ID", value: providerId)
            }
            if let retryAfterMs = metadata.retryAfterMs {
                metadataRow(label: "Retry After", value: "\(retryAfterMs) ms")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    ContentView()
}
