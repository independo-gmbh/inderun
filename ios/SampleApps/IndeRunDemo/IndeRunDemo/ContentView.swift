import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DemoViewModel()

    var body: some View {
        TabView {
            Tab("Text", systemImage: "text.bubble") {
                TextScreen(viewModel: viewModel)
            }
            Tab("Speech", systemImage: "speaker.wave.2") {
                SpeechScreen(viewModel: viewModel)
            }
        }
        // Above the tabs: a tab's task is cancelled when the user leaves it, which would abort
        // the model download.
        .task {
            await viewModel.ensureSelectedOnnxModelDownloaded()
            await viewModel.refreshAvailability()
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
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
