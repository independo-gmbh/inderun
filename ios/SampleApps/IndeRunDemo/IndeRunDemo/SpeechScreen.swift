import IndeRunContracts
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
                    controlsSection
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

    /// One row per control: a toggle turns it on, a slider sets it. A control the selected voice does
    /// not offer is disabled and says why; nothing is sent for a row that is off.
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech controls")
                .font(.headline)
            controlRow("Rate", id: .speechSpeakingRate, value: $viewModel.speechControls.rate, generates: true)
            controlRow("Pitch", id: .speechPitch, value: $viewModel.speechControls.pitch, generates: true)
            controlRow("Volume", id: .playbackVolume, value: $viewModel.speechControls.volume, generates: false)
            Toggle("Require rate", isOn: $viewModel.speechControls.requireRate)
        }
    }

    private func controlRow(
        _ label: String,
        id: SpeechControlId,
        value: Binding<Double?>,
        generates: Bool
    ) -> some View {
        let voice = viewModel.selectedSpeechVoice
        let speak = voice.controlSlider(id, delivery: .playback)
        let generate = generates ? voice.controlSlider(id, delivery: .artifact) : nil
        let slider = (speak.usable || generate == nil) ? speak : (generate ?? speak)
        let chosen = value.wrappedValue
        let note = ["Speak: \(voice.deliveryNote(id, delivery: .playback, value: chosen))"]
            + (generates ? ["Generate: \(voice.deliveryNote(id, delivery: .artifact, value: chosen))"] : [])
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(label + (value.wrappedValue.map { String(format: " %.2f", $0) } ?? ""), isOn: Binding(
                get: { value.wrappedValue != nil },
                set: { value.wrappedValue = $0 ? slider.initial : nil }
            ))
            .disabled(!slider.usable)
            if let current = value.wrappedValue, slider.usable {
                Slider(
                    value: Binding(get: { current }, set: { value.wrappedValue = $0 }),
                    in: slider.min...slider.max
                )
            }
            Text(note.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
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
