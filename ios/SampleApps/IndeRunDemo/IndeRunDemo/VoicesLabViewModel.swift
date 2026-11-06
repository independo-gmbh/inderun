import Foundation
import IndeRunAppleProviders
import IndeRunContracts
import IndeRunCore

/// A voice as the lab lists it (the SDK's `SpeechVoiceInfo`, reduced to what the screen and a request need).
struct LabVoice: Identifiable {
    let providerId: String
    let id: String
    let name: String
    let locale: String
    /// The request-side form of the voice (`SpeechVoiceInfo.asSpeechVoice()`); nil only in tests.
    let speechVoice: SpeechVoice?

    var key: String { "\(providerId)|\(id)|\(locale)" }
}

struct LabSpeakRequest {
    let text: String
    let locale: String
    let voice: SpeechVoice?
    /// The model profile the request routes within, never a model id.
    let profile: String
}

/// What the status card needs from a finished run.
struct SpokenSummary: Equatable {
    var providerId: String?
    var failedNeuralAttempt: String?
    var voiceName: String?
    var locale: String?
    var locality: String?
    var finishReason: String?
    var firstAudioMs: Int?
}

protocol LabPlayback: Sendable {
    func result() async throws -> SpokenSummary
    func cancel(reason: String)
}

/// The lab's own engine: Apple system speech plus one neural provider per installed entry
/// (see `AppleVoicesLabRuntime`).
@MainActor
protocol VoicesLabRuntime: AnyObject {
    /// Rebuilds the engine for these installed entries and registers `voices-lab:<id>` per entry.
    func install(_ entries: [CatalogEntry]) throws
    func listVoices(locale: String?) async -> [LabVoice]
    func speak(_ request: LabSpeakRequest) async throws -> any LabPlayback
    /// Loads the model ahead of the first run. One line per failed item; empty means ready.
    func warm(_ entry: CatalogEntry) async -> [String]
}

struct LabPreset: Identifiable, Equatable {
    let id: String
    let locale: String
    let text: String
}

struct VoicesLabState {
    var started = false
    /// True while the installed files are being checked at start.
    var isChecking = false
    var loadError: String?
    var installable: [CatalogEntry] = []
    /// Entries the catalog lists but this app cannot download, with the reason.
    var unavailable: [(CatalogEntry, String)] = []
    var installedIds: Set<String> = []
    /// An entry id, or `VoicesLabViewModel.control`.
    var selected = VoicesLabViewModel.control
    var locale = "de-DE"
    var text = "Der Bus kommt in fünf Minuten."
    var presets: [LabPreset] = []
    var voices: [LabVoice] = []
    var voiceKey: String?
    var pendingConsent: ConsentPrompt?
    var progress: (done: Int64, total: Int64)?
    var isDownloading = false
    var isWarming = false
    var isSpeaking = false
    var status: String?
    var card: [(String, String)] = []

    var isControl: Bool { selected == VoicesLabViewModel.control }
    var selectedEntry: CatalogEntry? { installable.first { $0.id == selected } }
    var canSpeakNeural: Bool { selectedEntry.map { installedIds.contains($0.id) } ?? false }

    /// Voices of the selected target: the OS voices for the control, else the entry's neural voices.
    var currentVoices: [LabVoice] {
        let wanted = isControl ? AppleSystemSpeechProvider.defaultId : selectedEntry.map { neuralProviderId($0.id) }
        return voices.filter { $0.providerId == wanted }
    }

    var selectedVoice: LabVoice? { currentVoices.first { $0.key == voiceKey } }
}

/// The card describes the provider that actually spoke, never the one that was asked: a neural
/// request answered by the OS voice reads "fell back to OS voice".
func statusCard(
    summary: SpokenSummary, askedNeural: Bool, entry: CatalogEntry?, requestedLocale: String, chosenVoiceName: String?
) -> (line: String, rows: [(String, String)]) {
    let neuralId = entry.map { neuralProviderId($0.id) }
    let neuralSpoke = askedNeural && summary.providerId == neuralId
    let fellBack = askedNeural && !neuralSpoke
    var note: String?
    if fellBack {
        var text = "fell back to OS voice"
        if let failed = summary.failedNeuralAttempt {
            text += " (neural: \(failed))"
        } else if summary.providerId == nil {
            text += " (provider not reported)"
        }
        note = text
    }
    let textOnnx = entry?.files.first { $0.path == "text.onnx" }
    var rows: [(String, String)] = []
    rows.append(("Provider", summary.providerId ?? (askedNeural ? "not reported" : AppleSystemSpeechProvider.defaultId)))
    if let note { rows.append(("Result", note)) }
    if neuralSpoke, let entry {
        rows.append(("Model", "\(entry.id) (\(entry.variant))"))
    } else if !fellBack {
        rows.append(("Model", "OS TTS (control)"))
    }
    if neuralSpoke, let textOnnx { rows.append(("Package checksum", "text.onnx sha256:\(textOnnx.sha256.prefix(12))…")) }
    rows.append(("Voice", summary.voiceName ?? (fellBack ? "automatic" : (chosenVoiceName ?? "automatic"))))
    rows.append(("Resolved locale", summary.locale ?? requestedLocale))
    rows.append(("Locality", summary.locality ?? "unknown"))
    if neuralSpoke {
        rows.append(("Runtime", "ONNX Runtime (CPU)"))
    } else if !fellBack {
        rows.append(("Runtime", "AVSpeechSynthesizer"))
    }
    rows.append(("Delivery", "playback (generateSpeech would return an artifact)"))
    rows.append(("Ended", summary.finishReason ?? "stop"))
    if let first = summary.firstAudioMs { rows.append(("First audio", "\(first) ms")) }
    let finish = summary.finishReason ?? "stop"
    let line = note.map { "\($0): \(finish)" } ?? "\(askedNeural ? "neural" : "OS voice"): \(finish)"
    return (line, rows)
}

/// The opt-in Voices lab (#260). Nothing happens until `setEnabled(true)`: no catalog read, no
/// provider registration, no storage access. Installation is checked read-only at start; files are
/// created only after the person consents. Download and playback stop only when the lab is switched
/// off (or the view model goes away), never because a view disappears.
@MainActor
final class VoicesLabViewModel: ObservableObject {
    nonisolated static let control = "control"
    nonisolated static let languages = ["de-DE", "de-AT", "en-US", "en-GB"]

    @Published private(set) var state = VoicesLabState()

    private(set) var startTask: Task<Void, Never>?
    private(set) var downloadTask: Task<Void, Never>?
    private(set) var speakTask: Task<Void, Never>?

    private let catalogSource: () throws -> Data
    private let corpusSource: () -> Data?
    private let installer: any NeuralModelInstalling
    private let runtime: any VoicesLabRuntime
    private var consentAnswer: CheckedContinuation<Bool, Never>?
    private var playback: (any LabPlayback)?
    private var stopRequested = false
    private var lastJob: (() async throws -> Void)?

    init(
        catalogSource: @escaping () throws -> Data,
        corpusSource: @escaping () -> Data?,
        installer: any NeuralModelInstalling,
        runtime: any VoicesLabRuntime
    ) {
        self.catalogSource = catalogSource
        self.corpusSource = corpusSource
        self.installer = installer
        self.runtime = runtime
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { shutdown() }
    }

    private func start() {
        guard !state.started else { return }
        state.started = true
        state.isChecking = true
        startTask = Task { [weak self] in
            await self?.load()
        }
    }

    private func load() async {
        let entries: [CatalogEntry]
        do {
            entries = try NeuralCatalogParser.parse(catalogSource())
        } catch {
            state.isChecking = false
            state.loadError = "could not read the model catalog: \(error.localizedDescription)"
            return
        }
        let installable = entries.filter(\.isInstallable)
        let unavailable = entries.filter { !$0.isInstallable }.map { ($0, $0.reviewNotes ?? $0.reviewStatus) }
        var installed: [CatalogEntry] = []
        for entry in installable {
            if Task.isCancelled { return }
            if await installer.isInstalled(entry) { installed.append(entry) }
        }
        guard !Task.isCancelled, state.started else { return }
        do {
            try runtime.install(installed)
        } catch {
            state.isChecking = false
            state.loadError = "could not start the Voices lab: \(error.localizedDescription)"
            return
        }
        let presets = Self.parsePresets(corpusSource())
        let first = presets.first { $0.locale == "de-DE" } ?? presets.first
        state.isChecking = false
        state.installable = installable
        state.unavailable = unavailable
        state.installedIds = Set(installed.map(\.id))
        state.selected = installed.first?.id ?? installable.first?.id ?? Self.control
        state.presets = presets
        if let first {
            state.text = first.text
            if Self.languages.contains(first.locale) { state.locale = first.locale }
        }
        await refreshVoices()
    }

    private static func parsePresets(_ data: Data?) -> [LabPreset] {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let utterances = root["utterances"] as? [[String: Any]] else { return [] }
        return utterances.compactMap { item in
            guard item["expect"] as? String != "refuse", let id = item["id"] as? String,
                  let locale = item["locale"] as? String, let text = item["text"] as? String else { return nil }
            return LabPreset(id: id, locale: locale, text: text)
        }
    }

    // MARK: - Controls

    func updateText(_ text: String) { state.text = text }

    func selectPreset(_ id: String) {
        guard let preset = state.presets.first(where: { $0.id == id }) else { return }
        state.text = preset.text
        if Self.languages.contains(preset.locale) { state.locale = preset.locale }
        Task { await refreshVoices() }
    }

    func updateLocale(_ locale: String) {
        state.locale = locale
        Task { await refreshVoices() }
    }

    func selectModel(_ id: String) {
        state.selected = id
        state.voiceKey = nil
        applyDefaultVoice()
    }

    func selectVoice(_ key: String?) { state.voiceKey = key }

    private func applyDefaultVoice() {
        state.voiceKey = state.isControl ? nil : state.currentVoices.first?.key
    }

    private func refreshVoices() async {
        let locale = state.locale
        let neural = await runtime.listVoices(locale: nil).filter { $0.providerId != AppleSystemSpeechProvider.defaultId }
        let control = await runtime.listVoices(locale: locale).filter { $0.providerId == AppleSystemSpeechProvider.defaultId }
        guard state.started else { return }
        state.voices = neural + control
        applyDefaultVoice()
    }

    // MARK: - Download and warm-up

    /// Downloads the selected entry after consent, or warms an installed one.
    func downloadOrWarm() {
        guard let entry = state.selectedEntry, !state.isDownloading, !state.isWarming else { return }
        let warming = state.installedIds.contains(entry.id)
        state.isDownloading = !warming
        state.isWarming = warming
        state.status = nil
        state.progress = nil
        downloadTask = Task { [weak self] in
            await self?.runDownloadOrWarm(entry, warming: warming)
        }
    }

    private func runDownloadOrWarm(_ entry: CatalogEntry, warming: Bool) async {
        defer {
            state.isDownloading = false
            state.isWarming = false
            state.progress = nil
            state.pendingConsent = nil
        }
        do {
            if warming {
                state.status = "Warming up \(entry.id)…"
                let failed = await runtime.warm(entry)
                try Task.checkCancellation()
                state.status = failed.isEmpty ? "\(entry.id) is ready." : "Warm-up failed: \(failed.joined(separator: "; "))"
                return
            }
            let result = try await installer.download(
                entry,
                consent: { [weak self] prompt in await self?.askConsent(prompt) ?? false },
                onProgress: { [weak self] done, total in
                    Task { @MainActor in self?.state.progress = (done, total) }
                }
            )
            switch result {
            case .declined:
                state.status = "Download declined; nothing was requested."
            case .installed:
                let ids = state.installedIds.union([entry.id])
                try runtime.install(state.installable.filter { ids.contains($0.id) })
                state.installedIds = ids
                state.status = "\(entry.id) installed."
                await refreshVoices()
            }
        } catch is CancellationError {
            state.status = warming ? "Warm-up cancelled." : "Download cancelled; verified files are kept, so a retry resumes."
        } catch {
            state.status = (error as? NeuralDownloadError)?.message ?? "failed: \(error.localizedDescription)"
        }
    }

    func cancelDownload() {
        // A pending consent counts as declined, so nothing is requested.
        answerConsent(false)
        downloadTask?.cancel()
    }

    /// Stops everything the lab started: called when the lab is switched off.
    private func shutdown() {
        startTask?.cancel()
        cancelDownload()
        stop()
        state.started = false
        state.isChecking = false
    }

    private func askConsent(_ prompt: ConsentPrompt) async -> Bool {
        // Cancelled, or the lab was switched off, before the sheet could show: it never shows.
        guard !Task.isCancelled, state.started else { return false }
        return await withCheckedContinuation { continuation in
            consentAnswer = continuation
            state.pendingConsent = prompt
        }
    }

    func answerConsent(_ accepted: Bool) {
        state.pendingConsent = nil
        let pending = consentAnswer
        consentAnswer = nil
        pending?.resume(returning: accepted)
    }

    // MARK: - Speaking

    func speakSelected() {
        launchJob { [weak self] in
            guard let self else { return }
            try await self.speakOnce(neural: !self.state.isControl)
        }
    }

    /// Neural voice first, then the OS control, one after the other.
    func compareAB() {
        launchJob { [weak self] in
            guard let self else { return }
            try await self.speakOnce(neural: true)
            if !self.stopRequested { try await self.speakOnce(neural: false) }
        }
    }

    func repeatLast() {
        guard let job = lastJob else { return }
        launchJob(remember: false, job)
    }

    func stop() {
        stopRequested = true
        playback?.cancel(reason: "stopped from the demo app")
    }

    private func launchJob(remember: Bool = true, _ job: @escaping () async throws -> Void) {
        guard !state.isSpeaking else { return }
        stopRequested = false
        if remember { lastJob = job }
        state.isSpeaking = true
        speakTask = Task { [weak self] in
            do {
                try await job()
            } catch is CancellationError {
                self?.state.status = "Stopped."
            } catch {
                self?.state.status = "failed: \((error as? IndeRunException).map { "\($0.errorClass.rawValue): \($0.message)" } ?? error.localizedDescription)"
            }
            self?.playback = nil
            self?.state.isSpeaking = false
        }
    }

    private func speakOnce(neural: Bool) async throws {
        let current = state
        let entry = current.selectedEntry
        if neural && !current.canSpeakNeural {
            state.status = "Download the model first."
            return
        }
        // The A/B control uses the OS voice list; a neural voice choice does not carry over.
        let chosen = neural == !current.isControl ? current.selectedVoice : nil
        let request = LabSpeakRequest(
            text: current.text,
            locale: current.locale,
            voice: chosen?.speechVoice,
            profile: neural ? labProfileName(entry?.id ?? "") : labControlProfile
        )
        state.status = neural ? "Speaking (neural)…" : "Speaking (OS voice)…"
        let started = try await runtime.speak(request)
        playback = started
        if stopRequested { started.cancel(reason: "stopped from the demo app") }
        let summary = try await started.result()
        playback = nil
        let card = statusCard(
            summary: summary, askedNeural: neural, entry: entry, requestedLocale: current.locale, chosenVoiceName: chosen?.name
        )
        state.status = card.line
        state.card = card.rows
    }
}

extension VoicesLabViewModel {
    /// The app's wiring: the bundled catalog and corpus, the consent downloader and the lab engine.
    /// Building it touches nothing; see `setEnabled`.
    static func makeDefault() -> VoicesLabViewModel {
        func bundled(_ name: String) -> Data? {
            Bundle.main.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        }
        return VoicesLabViewModel(
            catalogSource: {
                guard let data = bundled("neural-model-catalog") else {
                    throw NeuralCatalogError(description: "neural-model-catalog.json is not in the app bundle")
                }
                return data
            },
            corpusSource: { bundled("utterance-corpus") },
            installer: DemoNeuralModelDownloader(),
            runtime: AppleVoicesLabRuntime()
        )
    }
}
