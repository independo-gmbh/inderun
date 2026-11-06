import XCTest
@testable import IndeRunDemo

private let neuralId = "local.onnx.speech.apple:articulino-de-en-int8"

@MainActor
private final class FakeRuntime: VoicesLabRuntime {
    var installed: [[String]] = []
    var requests: [LabSpeakRequest] = []
    var summaries: [SpokenSummary] = []
    var warmFailures: [String] = []
    var playbackError: (any Error)?
    var voices: [LabVoice] = [
        LabVoice(providerId: neuralId, id: "de-at-m-1", name: "Austrian German man 1", locale: "de-AT", speechVoice: nil),
        LabVoice(providerId: "apple_system_speech", id: "os-1", name: "Anna", locale: "de-DE", speechVoice: nil),
    ]

    func install(_ entries: [CatalogEntry]) throws { installed.append(entries.map(\.id)) }
    func listVoices(locale: String?) async -> [LabVoice] { voices }

    func speak(_ request: LabSpeakRequest) async throws -> any LabPlayback {
        requests.append(request)
        let summary = summaries.isEmpty ? SpokenSummary(providerId: neuralId) : summaries.removeFirst()
        return FakePlayback(summary: summary, error: playbackError)
    }

    func warm(_ entry: CatalogEntry) async -> [String] { warmFailures }
}

private final class FakePlayback: LabPlayback, @unchecked Sendable {
    let summary: SpokenSummary
    let error: (any Error)?
    init(summary: SpokenSummary, error: (any Error)?) { self.summary = summary; self.error = error }
    func result() async throws -> SpokenSummary {
        if let error { throw error }
        return summary
    }
    func cancel(reason: String) {}
}

private final class FakeInstaller: NeuralModelInstalling, @unchecked Sendable {
    var installedIds: Set<String>
    var behaviour: @Sendable (@Sendable (ConsentPrompt) async -> Bool) async throws -> NeuralDownloadResult = { consent in
        let accepted = await consent(ConsentPrompt(entryId: "fake", totalBytes: 1, licenses: []))
        return accepted ? .installed : .declined
    }
    private(set) var checked = 0
    private(set) var downloads = 0

    init(installedIds: Set<String> = []) { self.installedIds = installedIds }

    func isInstalled(_ entry: CatalogEntry) async -> Bool {
        checked += 1
        return installedIds.contains(entry.id)
    }

    func download(
        _ entry: CatalogEntry, consent: @escaping @Sendable (ConsentPrompt) async -> Bool, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> NeuralDownloadResult {
        downloads += 1
        return try await behaviour(consent)
    }
}

@MainActor
final class VoicesLabViewModelTests: XCTestCase {
    private var catalogReads = 0

    private func catalog() throws -> Data {
        catalogReads += 1
        let url = try XCTUnwrap(Bundle(for: DemoViewModel.self).url(forResource: "neural-model-catalog", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func make(runtime: FakeRuntime, installer: FakeInstaller) -> VoicesLabViewModel {
        VoicesLabViewModel(catalogSource: { [unowned self] in try self.catalog() }, corpusSource: { nil }, installer: installer, runtime: runtime)
    }

    private func started(_ runtime: FakeRuntime, _ installer: FakeInstaller) async -> VoicesLabViewModel {
        let model = make(runtime: runtime, installer: installer)
        model.setEnabled(true)
        await model.startTask?.value
        return model
    }

    func testLabOffReadsNoCatalogAndRegistersNothing() async {
        let runtime = FakeRuntime()
        let installer = FakeInstaller()
        let model = make(runtime: runtime, installer: installer)
        model.setEnabled(false)
        await model.startTask?.value
        XCTAssertEqual(catalogReads, 0)
        XCTAssertEqual(installer.checked, 0)
        XCTAssertTrue(runtime.installed.isEmpty)
        XCTAssertFalse(model.state.started)
    }

    func testStartChecksInstallationAndShowsCoreAIAsUnavailable() async {
        let runtime = FakeRuntime()
        let model = await started(runtime, FakeInstaller(installedIds: ["articulino-de-en-int8"]))
        XCTAssertFalse(model.state.isChecking)
        XCTAssertEqual(runtime.installed, [["articulino-de-en-int8"]])
        XCTAssertEqual(model.state.unavailable.map(\.0.id), ["articulino-de-en-coreai"])
        XCTAssertFalse(model.state.unavailable[0].1.isEmpty)
        XCTAssertEqual(model.state.selected, "articulino-de-en-int8")
    }

    func testDeclinedConsentIsReportedAndInstallsNothing() async {
        let runtime = FakeRuntime()
        let installer = FakeInstaller()
        let model = await started(runtime, installer)
        model.downloadOrWarm()
        await waitForConsent(model)
        XCTAssertNotNil(model.state.pendingConsent)
        model.answerConsent(false)
        await model.downloadTask?.value
        XCTAssertEqual(model.state.status, "Download declined; nothing was requested.")
        XCTAssertTrue(model.state.installedIds.isEmpty)
    }

    func testAcceptedConsentInstallsAndRegistersTheEntry() async {
        let runtime = FakeRuntime()
        let model = await started(runtime, FakeInstaller())
        model.downloadOrWarm()
        await waitForConsent(model)
        model.answerConsent(true)
        await model.downloadTask?.value
        XCTAssertEqual(model.state.installedIds, ["articulino-de-en-int8"])
        XCTAssertEqual(runtime.installed.last, ["articulino-de-en-int8"])
    }

    func testDownloadFailureBecomesAStatusMessage() async {
        let installer = FakeInstaller()
        installer.behaviour = { _ in throw NeuralDownloadError("checksum mismatch: text.onnx") }
        let model = await started(FakeRuntime(), installer)
        model.downloadOrWarm()
        await model.downloadTask?.value
        XCTAssertEqual(model.state.status, "checksum mismatch: text.onnx")
        XCTAssertFalse(model.state.isDownloading)
    }

    func testSwitchingTheLabOffCancelsARunningDownload() async {
        let installer = FakeInstaller()
        installer.behaviour = { _ in
            try await Task.sleep(for: .seconds(60))
            return .installed
        }
        let model = await started(FakeRuntime(), installer)
        model.downloadOrWarm()
        await Task.yield()
        model.setEnabled(false)
        await model.downloadTask?.value
        XCTAssertEqual(model.state.status, "Download cancelled; verified files are kept, so a retry resumes.")
        XCTAssertFalse(model.state.isDownloading)
        XCTAssertFalse(model.state.started)
    }

    func testWarmUpFailuresAreSurfaced() async {
        let runtime = FakeRuntime()
        runtime.warmFailures = ["local.onnx.speech.apple: checksum mismatch"]
        let model = await started(runtime, FakeInstaller(installedIds: ["articulino-de-en-int8"]))
        model.downloadOrWarm()
        await model.downloadTask?.value
        XCTAssertEqual(model.state.status, "Warm-up failed: local.onnx.speech.apple: checksum mismatch")
    }

    func testSpeakingNeuralUsesTheLabProfileAndShowsTheModelThatSpoke() async {
        let runtime = FakeRuntime()
        let model = await started(runtime, FakeInstaller(installedIds: ["articulino-de-en-int8"]))
        model.speakSelected()
        await model.speakTask?.value
        XCTAssertEqual(runtime.requests.map(\.profile), ["voices-lab:articulino-de-en-int8"])
        let rows = Dictionary(uniqueKeysWithValues: model.state.card)
        XCTAssertEqual(rows["Provider"], neuralId)
        XCTAssertEqual(rows["Model"], "articulino-de-en-int8 (onnx-int8)")
        XCTAssertNil(rows["Result"])
    }

    func testAFallbackIsNamedAndNeverDescribedAsNeural() async {
        let runtime = FakeRuntime()
        runtime.summaries = [SpokenSummary(providerId: "apple_system_speech", failedNeuralAttempt: "failed, unavailable")]
        let model = await started(runtime, FakeInstaller(installedIds: ["articulino-de-en-int8"]))
        model.speakSelected()
        await model.speakTask?.value
        let rows = Dictionary(uniqueKeysWithValues: model.state.card)
        XCTAssertEqual(rows["Provider"], "apple_system_speech")
        XCTAssertEqual(rows["Result"], "fell back to OS voice (neural: failed, unavailable)")
        XCTAssertNil(rows["Model"])
        XCTAssertNil(rows["Runtime"])
        XCTAssertTrue(model.state.status?.hasPrefix("fell back to OS voice") == true)
    }

    func testABPlaysTheNeuralProfileThenTheControl() async {
        let runtime = FakeRuntime()
        runtime.summaries = [SpokenSummary(providerId: neuralId), SpokenSummary(providerId: "apple_system_speech")]
        let model = await started(runtime, FakeInstaller(installedIds: ["articulino-de-en-int8"]))
        model.compareAB()
        await model.speakTask?.value
        XCTAssertEqual(runtime.requests.map(\.profile), ["voices-lab:articulino-de-en-int8", "voices-lab:control"])
        XCTAssertNil(runtime.requests[1].voice)
    }

    func testAStoppedRunReportedAsCancelledLeavesTheSpeakingStatus() async {
        let runtime = FakeRuntime()
        runtime.summaries = [SpokenSummary(providerId: neuralId, finishReason: "cancelled")]
        let model = await started(runtime, FakeInstaller(installedIds: ["articulino-de-en-int8"]))
        model.speakSelected()
        await model.speakTask?.value
        XCTAssertEqual(model.state.status, "neural: cancelled")
        XCTAssertFalse(model.state.isSpeaking)
    }

    func testAStoppedRunThatThrowsCancellationLeavesTheSpeakingStatus() async {
        let runtime = FakeRuntime()
        runtime.playbackError = CancellationError()
        let model = await started(runtime, FakeInstaller(installedIds: ["articulino-de-en-int8"]))
        model.speakSelected()
        await model.speakTask?.value
        XCTAssertEqual(model.state.status, "Stopped.")
        XCTAssertFalse(model.state.isSpeaking)
    }

    func testNeuralSpeechNeedsTheModelFirst() async {
        let runtime = FakeRuntime()
        let model = await started(runtime, FakeInstaller())
        model.speakSelected()
        await model.speakTask?.value
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(model.state.status, "Download the model first.")
    }

    private func waitForConsent(_ model: VoicesLabViewModel) async {
        for _ in 0..<200 where model.state.pendingConsent == nil { await Task.yield() }
    }
}
