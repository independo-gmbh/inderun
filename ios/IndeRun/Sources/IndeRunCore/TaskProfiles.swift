import Foundation
import IndeRunContracts

/// What the engine needs to know about one task kind (ADR 016). This table is the only
/// place the engine branches on `task.kind`: the per-kind request rules, the projection
/// onto the planner's task requirements, and the output delivery a result must have.
/// Everything else -- routing, fallback, cancellation, provenance -- is task-agnostic, so
/// a new task adds an entry here rather than a second execution path.
///
/// The Web (`task-profiles.ts`) and Kotlin (`TaskProfiles.kt`) engines keep the same
/// table; `contracts/fixtures/task-contracts/` holds the planner projection all three
/// must produce for each request.
///
/// Swift has no JSON Schema validator, so `validate` restates the schema's per-kind
/// `if`/`then` branches of `task-request.schema.json` by hand.
package struct TaskProfile: Sendable {
    /// The `task.kind` this profile describes.
    package let kind: TaskKind
    /// The request's violations of this kind's rules, one human-readable issue each.
    package let validate: @Sendable (TaskRequest) -> [String]
    /// Projects the request onto the requirements the shared planner can check.
    package let plannerTask: @Sendable (TaskRequest) -> RoutePlannerInputTask
    /// The output delivery the request asks for: `inline` for text, else `delivery.mode`.
    package let delivery: @Sendable (TaskRequest) -> OutputDelivery
}

package enum TaskProfiles {
    /// The profile for `kind`. `TaskKind` is a closed enum, so a kind this engine cannot
    /// execute never decodes, and a kind added to the schema fails to compile here until
    /// it has a profile.
    package static func profile(for kind: TaskKind) -> TaskProfile {
        switch kind {
        case .textToText: return textToText
        case .textToSpeech: return textToSpeech
        }
    }

    private static let textToText = TaskProfile(
        kind: .textToText,
        validate: { request in
            var issues: [String] = []
            if let prompt = request.prompt, prompt.isEmpty {
                issues.append("prompt must be non-empty when provided.")
            }
            if let messages = request.messages, messages.contains(where: { $0.content.isEmpty }) {
                issues.append("messages[].content must be non-empty.")
            }
            if (request.prompt ?? "").isEmpty && (request.messages ?? []).isEmpty {
                issues.append("Either prompt or messages must be provided and non-empty.")
            }
            if request.speech != nil {
                issues.append("speech must not be set for task.kind 'text_to_text'.")
            }
            if request.delivery != nil {
                issues.append("delivery must not be set for task.kind 'text_to_text'.")
            }
            return issues
        },
        plannerTask: { _ in
            RoutePlannerInputTask(delivery: nil, inputs: [.text], kind: TaskKind.textToText.rawValue, locale: nil, voice: nil)
        },
        delivery: { _ in .inline }
    )

    private static let textToSpeech = TaskProfile(
        kind: .textToSpeech,
        validate: { request in
            var issues: [String] = []
            if request.prompt != nil {
                issues.append("prompt must not be set for task.kind 'text_to_speech'.")
            }
            if request.messages != nil {
                issues.append("messages must not be set for task.kind 'text_to_speech'.")
            }
            if request.generation != nil {
                issues.append("generation must not be set for task.kind 'text_to_speech'.")
            }
            if let speech = request.speech {
                issues += speechIssues(speech)
            } else {
                issues.append("speech must be provided for task.kind 'text_to_speech'.")
            }
            if let delivery = request.delivery {
                issues += deliveryIssues(delivery)
            } else {
                issues.append("delivery must be provided for task.kind 'text_to_speech'.")
            }
            return issues
        },
        plannerTask: { request in
            // Validation runs before projection and requires both; a request routed
            // without it projects only what it carries rather than trapping.
            RoutePlannerInputTask(
                delivery: request.delivery.map { DeliveryRequirement(mediaTypes: $0.mediaTypes, mode: $0.mode) },
                inputs: [.text],
                kind: TaskKind.textToSpeech.rawValue,
                locale: request.speech.map { LocaleRequirement(match: $0.localeMatch ?? .language, tag: $0.locale) },
                voice: request.speech?.voice.map {
                    VoiceRequirement(gender: $0.gender, requirement: $0.requirement ?? .preferred)
                }
            )
        },
        // Validation requires `delivery` for this kind; the fallback is never reached for
        // a validated request.
        delivery: { request in request.delivery?.mode ?? .playback }
    )

    private static func speechIssues(_ speech: SpeechInput) -> [String] {
        var issues: [String] = []
        if speech.text.isEmpty {
            issues.append("speech.text must be non-empty.")
        }
        if speech.locale.isEmpty {
            issues.append("speech.locale must be non-empty.")
        }
        if let voice = speech.voice, voice.requirement == .requirementLevelRequired, voice.gender == nil {
            issues.append("speech.voice.gender must be provided when speech.voice.requirement is 'required'.")
        }
        return issues
    }

    private static func deliveryIssues(_ delivery: OutputDeliveryRequest) -> [String] {
        var issues: [String] = []
        if delivery.mode == .inline {
            issues.append("delivery.mode must be 'playback' or 'artifact' for task.kind 'text_to_speech'.")
        }
        if let destinationRef = delivery.destinationRef {
            if delivery.mode != .artifact {
                issues.append("delivery.destinationRef is only valid with 'artifact' delivery.")
            }
            if destinationRef.isEmpty {
                issues.append("delivery.destinationRef must be non-empty.")
            }
        }
        if let mediaTypes = delivery.mediaTypes {
            if delivery.mode != .artifact {
                issues.append("delivery.mediaTypes is only valid with 'artifact' delivery.")
            }
            if mediaTypes.isEmpty || mediaTypes.contains(where: \.isEmpty) {
                issues.append("delivery.mediaTypes must be a non-empty list of non-empty media types.")
            }
            if Set(mediaTypes).count != mediaTypes.count {
                issues.append("delivery.mediaTypes must not repeat a media type.")
            }
        }
        return issues
    }
}

/// Re-checks, immediately before an attempt, that the voice the plan bound for this
/// provider still satisfies the request's privacy policy. The planner already chose the
/// voice inside that policy; repeating the check here keeps privacy enforceable at the
/// last point before data reaches the provider, independent of how the plan was produced.
/// A violation fails the attempt before commit, so the run may fall back.
///
/// - Returns: The exception to fail the attempt with, or `nil` when the voice is allowed.
package func recheckBoundVoice(
    request: TaskRequest,
    providerId: String,
    voice: ProviderVoice?
) -> IndeRunException? {
    guard voice?.networkRequired == true, request.constraints?.privacy == .localRequired else {
        return nil
    }
    return createCapabilityMismatch(
        message: "Provider '\(providerId)' was bound to a voice that sends data off the device, "
            + "which privacy=local_required forbids.",
        providerId: providerId,
        details: ["code": JSONAny("privacy_recheck_failed")]
    )
}

/// Checks a provider's output against the delivery the request asked for: inline text for
/// `inline`, a playback completion for `playback`, a media artifact for `artifact` whose
/// media type is one the request accepts. A provider never substitutes one for another
/// (ADR 016 §4), so a mismatch is a provider fault, not a result.
///
/// - Returns: The exception to fail the attempt with, or `nil` when the output matches.
package func checkOutput(
    request: TaskRequest,
    delivery: OutputDelivery,
    output: TaskOutput?,
    providerId: String
) -> IndeRunException? {
    let matches: Bool
    switch (delivery, output?.type) {
    case (.inline, .text?):
        matches = output?.text != nil
    case (.playback, .playback?):
        matches = output?.playback != nil
    case (.artifact, .artifact?):
        matches = output?.artifact.map { acceptsMediaType(request: request, $0.mediaType) } ?? false
    default:
        matches = false
    }
    if matches { return nil }
    let returned = output.map { "a '\($0.type.rawValue)' output" } ?? "no output"
    return createInternal(
        message: "Provider '\(providerId)' returned \(returned) for a '\(delivery.rawValue)' request.",
        providerId: providerId,
        details: ["code": JSONAny("output_mismatch")]
    )
}

/// Whether `mediaType` (parameters ignored, case-insensitive) is one the request accepts.
private func acceptsMediaType(request: TaskRequest, _ mediaType: String) -> Bool {
    guard let accepted = request.delivery?.mediaTypes else { return true }
    func base(_ type: String) -> String {
        (type.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
    return accepted.contains { base($0) == base(mediaType) }
}
