import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SmokeTestViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusSection
                    promptSection
                    actionSection
                    outputSection
                }
                .padding(20)
            }
            .navigationTitle("Apple On-Device Smoke Test")
            .task {
                await viewModel.refreshAvailability()
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider Status")
                .font(.headline)
            Text(viewModel.availabilityTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(viewModel.availabilityColor)
            Text(viewModel.availabilityMessage)
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
                    Text("Run on Device")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result")
                .font(.headline)

            if let outputText = viewModel.outputText {
                resultPanel(title: "Output", body: outputText, tint: .green)
            } else if let errorText = viewModel.errorText {
                resultPanel(title: "Error", body: errorText, tint: .red)
            } else {
                resultPanel(
                    title: "Idle",
                    body: "Run the prompt to capture either generated text or a normalized IndeRun error.",
                    tint: .secondary
                )
            }
        }
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
}

#Preview {
    ContentView()
}
