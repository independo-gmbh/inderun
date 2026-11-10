package app.independo.inderun.core

import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.SpeechModelPackage

/** A single model package validation problem. `path` is a JSON-pointer-style path, for example
 * `/source/ref`. */
data class ModelPackageValidationIssue(val path: String, val message: String)

/**
 * Minimal structural validation for [ModelPackage], mirroring the subset of
 * `getModelPackageValidationIssues` (`packages/contracts/src/validators.ts`, ported to Swift in
 * `ModelPackageValidation.swift` in `IndeRunCore`) that the provider's capability gate
 * needs: the `id` required field, the inline-secret-key rule, the `source.ref` URL-userinfo
 * rule, and the speech rules (`speech` is required when `tasks` contains `text_to_speech`, voice
 * ids are unique within it, and the structural rules: `sampleRate` and `channels` are at least 1,
 * `graphs` and `voices` are non-empty, and every voice lists at least one locale, each a hyphenated
 * BCP 47 tag). This is a hand-written subset, not a generated JSON Schema validator -- see the ONNX
 * Runtime provider family spec for the normative field shapes in
 * `contracts/schemas/model-package.schema.json`. Shared by every local-model provider.
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

    if (modelPackage.tasks?.contains("text_to_speech") == true && modelPackage.speech == null) {
        issues += ModelPackageValidationIssue("/speech", "required when tasks contains 'text_to_speech'")
    }

    modelPackage.speech?.voices?.let { voices ->
        if (voices.map { it.id }.toSet().size != voices.size) {
            issues += ModelPackageValidationIssue("/speech/voices", "voice ids must be unique")
        }
    }

    modelPackage.speech?.let { issues += findSpeechStructureIssues(it) }

    issues += findInlineSecretKeys(modelPackage)

    return issues
}

private val BCP47_TAG = Regex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")

/** Mirrors the structural constraints of `speech` in `model-package.schema.json`: numeric minimums,
 * non-empty `graphs`/`voices`, and per-voice `locales`. */
private fun findSpeechStructureIssues(speech: SpeechModelPackage): List<ModelPackageValidationIssue> {
    val issues = mutableListOf<ModelPackageValidationIssue>()

    if (speech.sampleRate < 1) {
        issues += ModelPackageValidationIssue("/speech/sampleRate", "must be >= 1")
    }
    speech.channels?.let { channels ->
        if (channels < 1) issues += ModelPackageValidationIssue("/speech/channels", "must be >= 1")
    }
    if (speech.graphs.isEmpty()) {
        issues += ModelPackageValidationIssue("/speech/graphs", "must list at least one graph")
    }
    if (speech.voices.isEmpty()) {
        issues += ModelPackageValidationIssue("/speech/voices", "must list at least one voice")
    }

    speech.voices.forEachIndexed { index, voice ->
        if (voice.locales.isEmpty()) {
            issues += ModelPackageValidationIssue("/speech/voices/$index/locales", "must list at least one locale")
        }
        voice.locales.forEachIndexed { localeIndex, locale ->
            if (!BCP47_TAG.matches(locale)) {
                issues += ModelPackageValidationIssue(
                    "/speech/voices/$index/locales/$localeIndex",
                    "must be a hyphenated BCP 47 tag",
                )
            }
        }
    }

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
