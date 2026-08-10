package app.independo.inderun.providers.onnx

import app.independo.inderun.contracts.ModelPackage

/** A single model package validation problem. `path` is a JSON-pointer-style path, for example
 * `/source/ref`. */
data class ModelPackageValidationIssue(val path: String, val message: String)

/**
 * Minimal structural validation for [ModelPackage], mirroring the subset of
 * `getModelPackageValidationIssues` (`packages/contracts/src/validators.ts`, ported to Swift in
 * `OnnxRuntimeAppleProvider`'s `ModelPackageValidation.swift`) that the provider's capability gate
 * needs: the `id` required field, the inline-secret-key rule, and the `source.ref` URL-userinfo
 * rule. This is a hand-written subset, not a generated JSON Schema validator -- see the ONNX
 * Runtime provider family spec for the normative field shapes in
 * `contracts/schemas/model-package.schema.json`.
 */
fun getModelPackageValidationIssues(modelPackage: ModelPackage): List<ModelPackageValidationIssue> {
    val issues = mutableListOf<ModelPackageValidationIssue>()

    if (modelPackage.id.trim().isEmpty()) {
        issues += ModelPackageValidationIssue("/id", "must not be empty")
    }

    modelPackage.source?.ref?.let { ref ->
        if (containsUrlUserinfo(ref)) {
            issues += ModelPackageValidationIssue(
                path = "/source/ref",
                message = "must not contain credentials (URL userinfo); use authContextRef instead",
            )
        }
    }

    issues += findInlineSecretKeys(modelPackage)

    return issues
}

/** Mirrors `isForbiddenSecretKey` in `packages/contracts/src/validators.ts`: rejects keys whose
 * normalized form contains a credential-shaped substring. */
private fun findInlineSecretKeys(modelPackage: ModelPackage): List<ModelPackageValidationIssue> {
    val checksums = modelPackage.integrity?.checksums ?: return emptyList()
    return checksums.keys.filter(::isForbiddenSecretKey).map { key ->
        ModelPackageValidationIssue(
            path = "/integrity/checksums/$key",
            message = "inline secrets are not allowed; use authContextRef instead",
        )
    }
}

private fun isForbiddenSecretKey(key: String): Boolean {
    val normalized = key.lowercase().filter { it.isLetterOrDigit() }
    return normalized.contains("authorization") ||
        normalized.contains("password") ||
        normalized.contains("secret") ||
        normalized.contains("apikey")
}

/** Mirrors the `source.ref` schema pattern `^(?![\s\S]*://[^/@]*@)[\s\S]*$`: rejects any
 * `scheme://userinfo@host` shape. */
private fun containsUrlUserinfo(value: String): Boolean {
    val schemeIndex = value.indexOf("://")
    if (schemeIndex < 0) return false
    val afterScheme = value.substring(schemeIndex + 3)
    val atIndex = afterScheme.indexOf('@')
    if (atIndex < 0) return false
    val authority = afterScheme.substring(0, atIndex)
    return !authority.contains("/")
}
