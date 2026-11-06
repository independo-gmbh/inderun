import SwiftUI

/// The opt-in Voices lab tab (#260): download the neural speech model with consent, pick a voice,
/// and hear it next to the OS voice.
struct VoicesLabScreen: View {
    @ObservedObject var lab: VoicesLabViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Downloads the Articulino neural speech model and seven demo voices after you agree, then speaks them next to the OS voice. Speech always routes as Local Only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    content
                }
                .padding(20)
            }
            .navigationTitle("Voices lab")
            .sheet(isPresented: consentBinding) { consentSheet }
        }
    }

    @ViewBuilder
    private var content: some View {
        let state = lab.state
        if state.isChecking {
            ProgressView("Checking installed files…")
        } else if let error = state.loadError {
            Text(error).font(.footnote).foregroundStyle(.red)
        } else {
            modelSection(state)
            textSection(state)
            voiceSection(state)
            actionSection(state)
            if let status = state.status {
                MetadataRow(label: "Status", value: status)
            }
            if !state.card.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.card.enumerated()), id: \.offset) { _, row in
                        MetadataRow(label: row.0, value: row.1)
                    }
                }
            }
        }
    }

    private func modelSection(_ state: VoicesLabState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model").font(.headline)
            Picker("Model", selection: Binding(get: { state.selected }, set: { lab.selectModel($0) })) {
                ForEach(state.installable) { entry in
                    Text(state.installedIds.contains(entry.id) ? "\(entry.id) (installed)" : entry.id).tag(entry.id)
                }
                Text("OS TTS (control)").tag(VoicesLabViewModel.control)
            }
            .pickerStyle(.menu)
            .buttonStyle(.bordered)

            if let entry = state.selectedEntry, !state.installedIds.contains(entry.id) {
                Text("Not installed: \(Self.megabytes(entry.totalBytes)) to download, after you agree.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.unavailable, id: \.0.id) { entry, reason in
                MetadataRow(label: "Unavailable", value: "\(entry.id): \(reason)")
            }
            if let progress = state.progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                Text("\(Self.megabytes(progress.done)) of \(Self.megabytes(progress.total))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if state.selectedEntry != nil {
                    Button {
                        lab.downloadOrWarm()
                    } label: {
                        Text(state.selectedEntry.map { state.installedIds.contains($0.id) } == true ? "Warm up" : "Download")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isDownloading || state.isWarming)
                }
                if state.isDownloading || state.isWarming {
                    Button(role: .destructive) {
                        lab.cancelDownload()
                    } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func textSection(_ state: VoicesLabState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text").font(.headline)
            TextField("Text to speak", text: Binding(get: { state.text }, set: { lab.updateText($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
            if !state.presets.isEmpty {
                Menu("Presets") {
                    ForEach(state.presets) { preset in
                        Button("\(preset.locale) · \(preset.id)") { lab.selectPreset(preset.id) }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func voiceSection(_ state: VoicesLabState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language and voice").font(.headline)
            Picker("Language", selection: Binding(get: { state.locale }, set: { lab.updateLocale($0) })) {
                ForEach(VoicesLabViewModel.languages, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .buttonStyle(.bordered)
            Picker("Voice", selection: Binding(get: { state.voiceKey }, set: { lab.selectVoice($0) })) {
                Text("Automatic").tag(String?.none)
                ForEach(state.currentVoices) { voice in
                    Text(voice.name).tag(voice.key as String?)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.bordered)
        }
    }

    private func actionSection(_ state: VoicesLabState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    lab.speakSelected()
                } label: {
                    Text("Speak").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isSpeaking || state.text.isEmpty)

                Button(role: .destructive) {
                    lab.stop()
                } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!state.isSpeaking)
            }
            HStack(spacing: 12) {
                Button {
                    lab.repeatLast()
                } label: {
                    Text("Repeat").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state.isSpeaking)

                Button {
                    lab.compareAB()
                } label: {
                    Text("A/B").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(state.isSpeaking || !state.canSpeakNeural)
            }
        }
    }

    // MARK: - Consent

    private var consentBinding: Binding<Bool> {
        Binding(
            get: { lab.state.pendingConsent != nil },
            // Swiping the sheet away is a refusal.
            set: { if !$0 { lab.answerConsent(false) } }
        )
    }

    @ViewBuilder
    private var consentSheet: some View {
        if let prompt = lab.state.pendingConsent {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Download \(Self.megabytes(prompt.totalBytes))?")
                            .font(.title3.weight(.semibold))
                        Text("Nothing has been requested yet. Agreeing downloads the model and seven voices to this app's storage, from Hugging Face and GitHub, and checks each file against its checksum.")
                            .font(.footnote)
                        ForEach(prompt.licenses, id: \.self) { line in
                            Text(line).font(.footnote).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button(role: .cancel) {
                                lab.answerConsent(false)
                            } label: {
                                Text("Decline").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button {
                                lab.answerConsent(true)
                            } label: {
                                Text("Download").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("Voices lab download")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Whole decimal megabytes, rounded half up; the web and Android demos use the same rule.
    static func megabytes(_ bytes: Int64) -> String {
        "\((bytes + 500_000) / 1_000_000) MB"
    }
}
