import AVFoundation
import Foundation
import IndeRunAppleProviders
import IndeRunContracts
import IndeRunCore
import IndeRunOnnxProviders
import IndeRunSwift

/// The Voices lab's engine (#260): Apple system speech plus one `NeuralSpeechProvider` per
/// installed catalog entry, and the model profiles `voices-lab:<entry id>` =
/// `[neural provider, apple_system_speech]` and `voices-lab:control` = `[apple_system_speech]`.
/// Requests name a profile, never a model id. The registry is fixed once an engine exists, so
/// `install` builds a new engine; it runs only when the lab is on, so a demo with the lab off
/// registers nothing. Core AI is not linked by this app, so its catalog entry stays unavailable.
@MainActor
final class AppleVoicesLabRuntime: VoicesLabRuntime {
    private lazy var hostServices = DefaultHostServices.make()
    private lazy var systemSpeech = AppleSystemSpeechProvider()
    /// One runtime for every install: it caches the loaded pipeline per package.
    private lazy var neuralRuntime = OnnxNeuralSpeechRuntime()
    private var engine: IndeRun?
    private var installed: [CatalogEntry] = []

    func install(_ entries: [CatalogEntry]) throws {
        installed = entries
        let registry = ProviderRegistry()
        try registry.register(systemSpeech)
        for entry in entries {
            let package = try catalogEntryToModelPackage(entry, ref: entry.ref)
            try registry.register(NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: package, runtime: neuralRuntime)))
        }
        let profiles = voicesLabProfiles(installedEntryIds: entries.map(\.id))
            .merging([labControlProfile: [AppleSystemSpeechProvider.defaultId]]) { current, _ in current }
        engine = IndeRun(registry: registry, hostServices: hostServices, modelProfiles: try ModelProfiles(profiles))
    }

    private func currentEngine() throws -> IndeRun {
        if engine == nil { try install(installed) }
        guard let engine else { throw NeuralCatalogError(description: "the Voices lab engine is not ready") }
        return engine
    }

    func listVoices(locale: String?) async -> [LabVoice] {
        guard let engine = try? currentEngine() else { return [] }
        return await engine.listVoices(locale: locale).compactMap { info in
            guard let id = info.id else { return nil }
            return LabVoice(
                providerId: info.providerId, id: id, name: info.name ?? id, locale: info.locale, speechVoice: info.asSpeechVoice()
            )
        }
    }

    func speak(_ request: LabSpeakRequest) async throws -> any LabPlayback {
        // The default session follows the Silent switch, which would mute a spoken answer.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let handle = try await currentEngine().speak(SpeakOptions(
            request.text,
            locale: request.locale,
            voice: request.voice,
            model: request.profile,
            execution: SpeechExecutionOptions(privacy: .localRequired)
        ))
        return SDKLabPlayback(handle: handle, neuralProviderId: request.profile == labControlProfile ? nil : neuralId(of: request.profile))
    }

    private func neuralId(of profile: String) -> String {
        neuralProviderId(String(profile.dropFirst("voices-lab:".count)))
    }

    func warm(_ entry: CatalogEntry) async -> [String] {
        do {
            let request = PrepareRequest(
                allowDownload: false, locale: nil, localeMatch: nil, privacy: nil, requestId: nil,
                tasks: ["text_to_speech"],
                voice: PrepareVoice(gender: nil, id: nil, providerId: neuralProviderId(entry.id))
            )
            let result = try await currentEngine().prepare(request).result()
            let failed = result.items.filter { $0.status == .failed }.map { "\($0.providerId): \($0.reason ?? "failed")" }
            return result.cancelled ? failed + ["cancelled"] : failed
        } catch {
            return ["\(error.localizedDescription)"]
        }
    }
}

private struct SDKLabPlayback: LabPlayback {
    let handle: SpeechPlayback
    let neuralProviderId: String?

    func result() async throws -> SpokenSummary {
        let done = try await handle.result()
        let failed = done.provenance?.attempts
            .first { $0.providerId == neuralProviderId && $0.outcome != .succeeded }
            .map { attempt in
                "\(attempt.outcome.rawValue)\(attempt.errorClass.map { ", \($0.rawValue)" } ?? "")"
            }
        return SpokenSummary(
            providerId: done.provenance?.providerId,
            failedNeuralAttempt: failed,
            voiceName: done.speech?.voice?.name,
            locale: done.speech?.locale,
            locality: done.provenance?.locality.rawValue,
            finishReason: done.finishReason?.rawValue,
            firstAudioMs: done.timing?.firstAudioMs.map { Int($0) }
        )
    }

    func cancel(reason: String) { handle.cancel(reason: reason) }
}
