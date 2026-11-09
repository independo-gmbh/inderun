import SwiftUI

struct SpeechScreen: View {
    @ObservedObject var viewModel: DemoViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introSection
                    textSection
                    languageSection
                    actionSection
                    voicesLabSection
                    if let outcome = viewModel.speechOutcome {
                        MetadataRow(label: "Outcome", value: outcome)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Text to Speech")
            // Runs on every visit and on every return to the app: voices are installed in Settings.
            .task(id: scenePhase) {
                if scenePhase == .active {
                    await viewModel.refreshSpeechLocales()
                }
            }
            .task(id: viewModel.speechVoiceId) {
                await viewModel.prepareSpeech()
            }
        }
    }

    private var introSection: some View {
        Text("A system voice speaks the text on this device. Speech always routes as Local Only, so the Privacy Preference on the Text tab does not apply here.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text")
                .font(.headline)
            TextField("Text to speak", text: $viewModel.speechText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language")
                .font(.headline)

            switch viewModel.speechLocalesState {
            case .loading:
                languageHint("Checking installed voices...")
            case .failed:
                languageHint("Unable to list voices.")
            case .ready(let locales) where locales.isEmpty:
                languageHint("This device has no voices. Add one in Settings under Accessibility, then come back.")
            case .ready(let locales):
                Picker("Language", selection: $viewModel.speechLocale) {
                    ForEach(locales) { locale in
                        Text(locale.name).tag(locale.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .buttonStyle(.bordered)

                Picker("Voice", selection: $viewModel.speechVoiceId) {
                    Text("Automatic").tag(String?.none)
                    ForEach(viewModel.speechVoiceOptions) { voice in
                        Text(voice.label).tag(voice.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .buttonStyle(.bordered)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.speak() }
            } label: {
                Text("Speak")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canSpeak)

            Button(role: .destructive) {
                viewModel.stopSpeaking()
            } label: {
                Text("Stop")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canStopSpeaking)

            Button {
                Task { await viewModel.synthesizeSpeech() }
            } label: {
                Text("Synthesize")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canSpeak)
        }
    }

    private var voicesLabSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Voices lab", isOn: $viewModel.voicesLabEnabled)
            Text("Adds a tab to download a neural voice model (about 113 MB, after you agree) and compare it with the OS voice. Off by default; while off, nothing is fetched or registered.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func languageHint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
