import Foundation
import IndeRunContracts

/// A single model package validation problem.
public struct ModelPackageValidationIssue: Equatable, Sendable {
    /// JSON-pointer-style path to the offending field, for example `/source/ref`.
    public let path: String
    /// Human-readable description of the problem.
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Minimal structural validation for `ModelPackage`, mirroring the subset of
/// `getModelPackageValidationIssues` (`packages/contracts/src/validators.ts`) that the provider's
/// capability gate needs: the schema's `required` fields, the inline-secret-key rule, the
/// `source.ref` URL-userinfo rule, and the speech rules (`speech` is required when `tasks` contains
/// `text_to_speech`, voice ids are unique within it, and the structural rules: `sampleRate` and
/// `channels` are at least 1, `graphs` and `voices` are non-empty, and every voice lists at least one
/// locale, each a hyphenated BCP 47 tag). This is a hand-written subset, not a generated JSON Schema
/// validator (no AJV-equivalent exists in Swift) -- see the ONNX Runtime provider family spec
/// for the normative field shapes in `contracts/schemas/model-package.schema.json`. Shared by
/// every local-model provider.
public func getModelPackageValidationIssues(_ modelPackage: ModelPackage) -> [ModelPackageValidationIssue] {
    var issues: [ModelPackageValidationIssue] = []

    if modelPackage.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(ModelPackageValidationIssue(path: "/id", message: "must not be empty"))
    }

    if let ref = modelPackage.source?.ref, containsUrlUserinfo(ref) {
        issues.append(
            ModelPackageValidationIssue(
                path: "/source/ref",
                message: "must not contain credentials (URL userinfo); use authContextRef instead"
            )
        )
    }

    if modelPackage.tasks?.contains("text_to_speech") == true, modelPackage.speech == nil {
        issues.append(
            ModelPackageValidationIssue(path: "/speech", message: "required when tasks contains 'text_to_speech'")
        )
    }

    if let voices = modelPackage.speech?.voices, Set(voices.map(\.id)).count != voices.count {
        issues.append(ModelPackageValidationIssue(path: "/speech/voices", message: "voice ids must be unique"))
    }

    if let speech = modelPackage.speech {
        issues.append(contentsOf: findSpeechStructureIssues(in: speech))
    }

    issues.append(contentsOf: findInlineSecretKeys(in: modelPackage))

    return issues
}

private let bcp47TagPattern = try? Regex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")

/// Whole-string match (`$` in a search would also accept a trailing newline, unlike Ajv and Kotlin).
private func isBcp47Tag(_ tag: String) -> Bool {
    guard let pattern = bcp47TagPattern else { return false }
    return tag.wholeMatch(of: pattern) != nil
}

/// Mirrors the structural constraints of `speech` in `model-package.schema.json`: numeric minimums,
/// non-empty `graphs`/`voices`, and per-voice `locales`.
private func findSpeechStructureIssues(in speech: SpeechModelPackage) -> [ModelPackageValidationIssue] {
    var issues: [ModelPackageValidationIssue] = []

    if speech.sampleRate < 1 {
        issues.append(ModelPackageValidationIssue(path: "/speech/sampleRate", message: "must be >= 1"))
    }
    if let channels = speech.channels, channels < 1 {
        issues.append(ModelPackageValidationIssue(path: "/speech/channels", message: "must be >= 1"))
    }
    if speech.graphs.isEmpty {
        issues.append(ModelPackageValidationIssue(path: "/speech/graphs", message: "must list at least one graph"))
    }
    if speech.voices.isEmpty {
        issues.append(ModelPackageValidationIssue(path: "/speech/voices", message: "must list at least one voice"))
    }

    for (index, voice) in speech.voices.enumerated() {
        if voice.locales.isEmpty {
            issues.append(
                ModelPackageValidationIssue(
                    path: "/speech/voices/\(index)/locales",
                    message: "must list at least one locale"
                )
            )
        }
        for (localeIndex, locale) in voice.locales.enumerated()
        where !isBcp47Tag(locale) {
            issues.append(
                ModelPackageValidationIssue(
                    path: "/speech/voices/\(index)/locales/\(localeIndex)",
                    message: "must be a hyphenated BCP 47 tag"
                )
            )
        }
    }

    return issues
}

/// Mirrors `isForbiddenSecretKey` in `packages/contracts/src/validators.ts`: rejects keys whose
/// normalized form contains a credential-shaped substring. `ModelPackage`'s known fields never
/// legitimately hold secrets, so this only guards `Files.external`/`Integrity.checksums`-style
/// free-form maps a caller might misuse.
private func findInlineSecretKeys(in modelPackage: ModelPackage) -> [ModelPackageValidationIssue] {
    var issues: [ModelPackageValidationIssue] = []

    if let checksums = modelPackage.integrity?.checksums {
        for key in checksums.keys where isForbiddenSecretKey(key) {
            issues.append(
                ModelPackageValidationIssue(
                    path: "/integrity/checksums/\(key)",
                    message: "inline secrets are not allowed; use authContextRef instead"
                )
            )
        }
    }

    return issues
}

private func isForbiddenSecretKey(_ key: String) -> Bool {
    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
    return normalized.contains("authorization")
        || normalized.contains("password")
        || normalized.contains("secret")
        || normalized.contains("apikey")
}

/// Mirrors the `source.ref` schema pattern
/// `^(?![\s\S]*://[^/@]*@)[\s\S]*$`: rejects any `scheme://userinfo@host` shape.
private func containsUrlUserinfo(_ value: String) -> Bool {
    guard let schemeRange = value.range(of: "://") else { return false }
    let afterScheme = value[schemeRange.upperBound...]
    guard let atIndex = afterScheme.firstIndex(of: "@") else { return false }
    let authority = afterScheme[afterScheme.startIndex..<atIndex]
    return !authority.contains("/")
}
