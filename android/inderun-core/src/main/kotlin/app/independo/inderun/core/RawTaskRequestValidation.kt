package app.independo.inderun.core

import app.independo.inderun.contracts.RequirementLevel
import app.independo.inderun.contracts.SchemaVersion
import org.json.JSONObject

/**
 * Checks a raw, not yet parsed `TaskRequest` JSON object for what a hand-written parser would lose
 * (ADR 025).
 *
 * The Kotlin contracts have no JSON decoder, and a parser that reads only the keys it knows drops
 * the rest, so a misspelled control such as `speech.controls.speakingrate` would parse as no control
 * at all, and a misspelled required control would vanish before any validation sees it. A JSON entry
 * point that turns a request it did not build itself into a [app.independo.inderun.contracts.TaskRequest]
 * (a bridge, a message channel) calls this first and refuses the request when it returns any issue.
 *
 * It is a targeted check, not a schema engine: it covers the schema version and the closed control
 * objects (`speech.controls`, `delivery.playback` and the requested numbers inside them), which are
 * the only places where silent loss changes what executes. Everything else is checked after parsing
 * by the engine's request validation, as for typed callers. The Swift SDK has the same check
 * (`RawTaskRequestValidation`); `contracts/fixtures/task-contracts/` holds the shared cases.
 *
 * @return One human-readable issue per problem; empty when nothing that parsing would lose is wrong.
 */
fun rawTaskRequestIssues(request: JSONObject): List<String> = buildList {
    if (request.opt("schemaVersion") != SchemaVersion.V1_1.rawValue) {
        add("schemaVersion must be '${SchemaVersion.V1_1.rawValue}'.")
    }
    request.optJSONObject("speech")?.opt("controls")?.let { controls ->
        addAll(closedObjectIssues(controls, "speech.controls", setOf("speakingRate", "pitch")))
    }
    request.optJSONObject("delivery")?.opt("playback")?.let { playback ->
        addAll(closedObjectIssues(playback, "delivery.playback", setOf("volume")))
    }
}

private fun closedObjectIssues(value: Any, path: String, keys: Set<String>): List<String> {
    if (value !is JSONObject) return listOf("$path must be an object.")
    return buildList {
        value.keys().asSequence().filterNot { it in keys }.sorted().forEach { add("$path.$it is not a known control.") }
        for (key in keys.sorted()) {
            value.opt(key)?.let { addAll(requestedNumberIssues(it, "$path.$key")) }
        }
    }
}

private fun requestedNumberIssues(value: Any, path: String): List<String> {
    if (value !is JSONObject) return listOf("$path must be an object.")
    return buildList {
        value.keys().asSequence().filterNot { it == "value" || it == "requirement" }.sorted()
            .forEach { add("$path.$it is not allowed.") }
        val number = value.opt("value")
        // org.json reads JSON booleans as Boolean, never as Number. The domain is checked after parsing.
        if (number !is Number || !number.toDouble().isFinite()) add("$path.value must be a finite number.")
        if (value.has("requirement")) {
            val requirement = value.opt("requirement")
            if (requirement !is String || RequirementLevel.fromRawValue(requirement) == null) {
                add("$path.requirement must be 'preferred' or 'required'.")
            }
        }
    }
}
