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
            RoutePlannerInputTask(
                controls: nil,
                delivery: nil,
                inputs: [.text],
                kind: TaskKind.textToText.rawValue,
                locale: nil,
                voice: nil
            )
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
                controls: controlRequirements(request),
                delivery: request.delivery.map { DeliveryRequirement(mediaTypes: $0.mediaTypes, mode: $0.mode) },
                inputs: [.text],
                kind: TaskKind.textToSpeech.rawValue,
                locale: request.speech.map { LocaleRequirement(match: $0.localeMatch ?? .language, tag: $0.locale) },
                voice: request.speech?.voice.map {
                    VoiceRequirement(
                        gender: $0.gender,
                        id: $0.id,
                        providerId: $0.providerId,
                        requirement: $0.requirement ?? .preferred
                    )
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
        if let voice = speech.voice, voice.id != nil, voice.providerId == nil {
            issues.append("speech.voice.providerId must be provided with speech.voice.id.")
        }
        if let voice = speech.voice, voice.requirement == .requirementLevelRequired,
           voice.gender == nil, voice.id == nil {
            issues.append("speech.voice must name an id or a gender when speech.voice.requirement is 'required'.")
        }
        if let rate = speech.controls?.speakingRate, !(rate.value.isFinite && rate.value > 0) {
            issues.append("speech.controls.speakingRate.value must be a finite number greater than 0.")
        }
        if let pitch = speech.controls?.pitch, !(pitch.value.isFinite && pitch.value > 0) {
            issues.append("speech.controls.pitch.value must be a finite number greater than 0.")
        }
        return issues
    }

    /// The request's speech controls in the planner's fixed order, or `nil` when it names
    /// none, so a request without controls projects as before.
    private static func controlRequirements(_ request: TaskRequest) -> [ControlRequirement]? {
        let controls = requestedControls(request)
        return controls.isEmpty ? nil : controls
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
        if let playback = delivery.playback {
            if delivery.mode != .playback {
                issues.append("delivery.playback is only valid with 'playback' delivery.")
            }
            if let volume = playback.volume, !(volume.value.isFinite && volume.value >= 0 && volume.value <= 1) {
                issues.append("delivery.playback.volume.value must be a finite number from 0 to 1.")
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

/// The speech controls the request names, in the planner's fixed order (rate, pitch, volume),
/// with the requirement defaulted to `preferred`. Empty for a request that names none. Every
/// control check below compares against this list, so all of them read the request the way the
/// planner does.
package func requestedControls(_ request: TaskRequest) -> [ControlRequirement] {
    var controls: [ControlRequirement] = []
    if let rate = request.speech?.controls?.speakingRate {
        controls.append(
            ControlRequirement(id: .speechSpeakingRate, requirement: rate.requirement ?? .preferred, value: rate.value)
        )
    }
    if let pitch = request.speech?.controls?.pitch {
        controls.append(
            ControlRequirement(id: .speechPitch, requirement: pitch.requirement ?? .preferred, value: pitch.value)
        )
    }
    if let volume = request.delivery?.playback?.volume {
        controls.append(
            ControlRequirement(id: .playbackVolume, requirement: volume.requirement ?? .preferred, value: volume.value)
        )
    }
    return controls
}

/// Checks, after planning and before the first attempt, the control application plan of every
/// candidate the engine will attempt, fallbacks included, against the request (ADR 025 section 3).
/// The planner boundary carries no version, so a route core built without plans would return
/// candidates with none, and a required control would silently vanish: a missing plan is not an
/// empty request.
///
/// It takes the route selection's chain, not the plan's candidates: a selected provider the plan
/// lists no candidate for is still attempted, with no plan, and must be checked like any other.
///
/// - Returns: `Internal` with `details.code: control_plan_mismatch` for the first candidate whose
///   plan does not match, or `nil` when every plan does. No attempt may follow a mismatch.
package func checkControlPlans(request: TaskRequest, candidates: [RouteCandidate]) -> IndeRunException? {
    let requested = requestedControls(request)
    guard let mismatched = candidates.first(where: { !controlPlanMatches(requested, plan: $0.controls) }) else {
        return nil
    }
    let providerId = mismatched.provider.describe().id
    return createInternal(
        message: "The route plan for provider '\(providerId)' does not match the request's speech controls.",
        details: ["code": JSONAny("control_plan_mismatch")]
    )
}

/// Whether `plan` is consistent with `requested`: one entry per requested control, in request
/// order, with the request's id, value and requirement, and `apply` for every required one. An
/// `omit` entry carries its reason and an `apply` entry none.
/// Absent and empty plans are the same, so they match only a request without controls, and any
/// entry on a request without controls is a mismatch.
package func controlPlanMatches(_ requested: [ControlRequirement], plan: [ControlApplicationPlan]?) -> Bool {
    let entries = plan ?? []
    guard entries.count == requested.count else { return false }
    return zip(requested, entries).allSatisfy { control, entry in
        entry.id == control.id
            && entry.value == control.value
            && entry.requirement == control.requirement
            // An omission carries its reason (the outcome record's reason); an application none.
            && (entry.reason == nil) == (entry.decision == .apply)
            && (control.requirement != .requirementLevelRequired || entry.decision == .apply)
    }
}

/// How the run a provider's control records belong to ended.
package enum ControlOutcomeEnding: Sendable {
    case completed
    case cancelled
}

/// The method an applied control must report: volume attenuates playback, rate and pitch are
/// synthesized (ADR 025 section 4).
package func controlMethodFor(_ id: SpeechControlId) -> SpeechControlMethod {
    id == .playbackVolume ? .playbackAttenuation : .platformSynthesis
}

/// Validates the control records a provider reported and completes them (ADR 025 section 4).
/// The result has one record per requested control, in request order: the provider's record where
/// it reported one, otherwise `not_applied` with `not_reported`. Application is never inferred
/// from the request.
///
/// Refused, for any ending: a duplicate record, a record for a control the request did not name,
/// a `requested` value that is not the request's, an `applied` record whose method does not match
/// the control's phase (a missing method included), a `not_applied` record without a reason.
/// Refused only for a `completed` ending: a required control without an `applied` record. A
/// `cancelled` ending keeps what was reported, because a stop is an ending, not a failure.
/// (An unknown status or reason cannot occur: the contract enums are closed and decode refuses
/// them.)
///
/// - Throws: `Internal` with `details.code: output_mismatch`.
package func completeControlOutcomes(
    request: TaskRequest,
    reported: [SpeechControlOutcome]?,
    ending: ControlOutcomeEnding,
    providerId: String
) throws -> [SpeechControlOutcome] {
    func mismatch(_ problem: String) -> IndeRunException {
        createInternal(
            message: "Provider '\(providerId)' reported speech control records \(problem).",
            providerId: providerId,
            details: ["code": JSONAny("output_mismatch")]
        )
    }
    let requested = requestedControls(request)
    var records: [SpeechControlId: SpeechControlOutcome] = [:]
    for record in reported ?? [] {
        guard let control = requested.first(where: { $0.id == record.id }) else {
            throw mismatch("for '\(record.id.rawValue)', which the request did not name")
        }
        if records[record.id] != nil { throw mismatch("with '\(record.id.rawValue)' twice") }
        if record.requested != control.value {
            throw mismatch("with '\(record.id.rawValue)' requested at \(record.requested), not \(control.value)")
        }
        switch record.status {
        case .applied:
            if record.method != controlMethodFor(control.id) {
                throw mismatch("with '\(record.id.rawValue)' applied by '\(record.method?.rawValue ?? "no method")'")
            }
        case .notApplied:
            if record.reason == nil {
                throw mismatch("with '\(record.id.rawValue)' not applied for no known reason")
            }
        }
        records[record.id] = record
    }
    if ending == .completed,
       let unmet = requested.first(where: {
           $0.requirement == .requirementLevelRequired && records[$0.id]?.status != .applied
       }) {
        throw mismatch("without required '\(unmet.id.rawValue)' applied")
    }
    return requested.map { control in
        records[control.id] ?? SpeechControlOutcome(
            effective: nil, id: control.id, method: nil, reason: .notReported, requested: control.value,
            status: .notApplied
        )
    }
}

/// Completes the control records of a completed run's output (see ``completeControlOutcomes``).
/// A request without controls leaves the output as it is, and refuses one that carries records.
/// Records live only in the output's `speech` section, so an output without one has none. For a
/// request whose controls are all preferred it passes unchanged, with no section and no records,
/// because the engine never invents the locale a section states; with a required control it is
/// refused, since nothing says it was applied.
///
/// - Throws: `Internal` with `details.code: output_mismatch`.
package func completeOutputControls(request: TaskRequest, output: TaskOutput, providerId: String) throws -> TaskOutput {
    let reported = output.speech?.controls
    let requested = requestedControls(request)
    if requested.isEmpty {
        _ = try completeControlOutcomes(request: request, reported: reported, ending: .completed, providerId: providerId)
        return output
    }
    guard var speech = output.speech else {
        if requested.allSatisfy({ $0.requirement != .requirementLevelRequired }) { return output }
        throw createInternal(
            message: "Provider '\(providerId)' reported no speech outcome for a request with a required speech control.",
            providerId: providerId,
            details: ["code": JSONAny("output_mismatch")]
        )
    }
    speech.controls = try completeControlOutcomes(
        request: request, reported: reported, ending: .completed, providerId: providerId
    )
    var completed = output
    completed.speech = speech
    return completed
}

/// The speech section of a cancelled terminal outcome, from what the attempt reported through
/// `RunContext.reportSpeech` before the stop: the reported records are kept and every other
/// requested control becomes `not_applied` / `not_reported`. A report that breaks the record
/// rules cannot fail a cancelled run, so none of its records is trusted: every requested control
/// is then `not_reported`. Without a report there is no section, since nothing says which locale
/// was spoken.
package func cancelledSpeechOutcome(
    request: TaskRequest,
    reported: SpeechOutput?,
    providerId: String
) -> SpeechOutput? {
    guard var speech = reported else { return nil }
    let kept = try? completeControlOutcomes(
        request: request, reported: speech.controls, ending: .cancelled, providerId: providerId
    )
    let controls = kept
        ?? (try? completeControlOutcomes(request: request, reported: nil, ending: .cancelled, providerId: providerId))
        ?? []
    speech.controls = controls.isEmpty ? nil : controls
    return speech
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
