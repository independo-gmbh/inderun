import Foundation
import IndeRunContracts

/// A single model package validation problem.
public struct ModelPackageValidationIssue: Equatable, Sendable {
    /// JSON-pointer-style path to the offending field, for example `/source/ref`.
    public let path: String
    /// Human-readable description of the problem.
    public let message: String
}

/// Minimal structural validation for `ModelPackage`, mirroring the subset of
/// `getModelPackageValidationIssues` (`packages/contracts/src/validators.ts`) that the provider's
/// capability gate needs: the schema's `required` fields, the inline-secret-key rule, and the
/// `source.ref` URL-userinfo rule. This is a hand-written subset, not a generated JSON Schema
/// validator (no AJV-equivalent exists in Swift) -- see the ONNX Runtime provider family spec
/// for the normative field shapes in `contracts/schemas/model-package.schema.json`.
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

    issues.append(contentsOf: findInlineSecretKeys(in: modelPackage))

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
