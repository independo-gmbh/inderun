import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DemoViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introSection
                    executionSection
                    availabilitySection
                    cloudSettingsSection
                    promptSection
                    actionSection
                    resultSection
                }
                .padding(20)
            }
            .navigationTitle("IndeRun Demo")
            .task {
                await viewModel.refreshAvailability()
            }
        }
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run the same text request through either Apple Foundation Models on-device or a cloud endpoint exposed through the demo proxy.")
                .font(.body)
            Text("Routing is explicit in this demo. It does not automatically fall back between providers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Execution Mode")
                .font(.headline)
            Picker("Execution Mode", selection: $viewModel.executionMode) {
                ForEach(DemoViewModel.ExecutionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(viewModel.executionModeDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Availability")
                .font(.headline)
            availabilityCard(title: DemoViewModel.ExecutionMode.onDevice.title, state: viewModel.onDeviceStatus)
            availabilityCard(title: DemoViewModel.ExecutionMode.cloud.title, state: viewModel.cloudStatus)
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
                    Text(viewModel.runButtonTitle)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canRun)
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

    private func availabilityCard(title: String, state: DemoViewModel.AvailabilityState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(state.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(state.color)
            Text(state.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
