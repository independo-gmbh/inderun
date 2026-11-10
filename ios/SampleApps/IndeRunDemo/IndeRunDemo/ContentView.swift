import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DemoViewModel()
    // Built idle: nothing is read, registered or downloaded until the lab is switched on.
    @StateObject private var lab = VoicesLabViewModel.makeDefault()

    var body: some View {
        TabView {
            Tab("Text", systemImage: "text.bubble") {
                TextScreen(viewModel: viewModel)
            }
            Tab("Speech", systemImage: "speaker.wave.2") {
                SpeechScreen(viewModel: viewModel)
            }
            if viewModel.voicesLabEnabled {
                Tab("Voices lab", systemImage: "waveform") {
                    VoicesLabScreen(lab: lab)
                }
            }
        }
        // On the TabView, not on the lab's screen: leaving the tab must not stop a download.
        // Only switching the lab off does.
        .onChange(of: viewModel.voicesLabEnabled, initial: true) { _, enabled in
            lab.setEnabled(enabled)
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
