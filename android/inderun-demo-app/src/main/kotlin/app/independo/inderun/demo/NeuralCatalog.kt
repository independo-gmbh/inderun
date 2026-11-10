package app.independo.inderun.demo

import app.independo.inderun.contracts.AssetLicense
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.FrontendKind
import app.independo.inderun.contracts.Integrity
import app.independo.inderun.contracts.License
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.Runtime
import app.independo.inderun.contracts.Source
import app.independo.inderun.contracts.SourceType
import app.independo.inderun.contracts.SpeechFrontend
import app.independo.inderun.contracts.SpeechModelPackage
import app.independo.inderun.contracts.SpeechModelVoice
import app.independo.inderun.contracts.VoiceGender
import app.independo.inderun.providers.neuralspeech.NeuralSpeechProvider
import app.independo.inderun.providers.systemspeech.AndroidSystemSpeechProvider
import org.json.JSONArray
import org.json.JSONObject

// The demo's view of contracts/fixtures/speech/neural-model-catalog.json (#260). The shape is pinned
// by packages/contracts/src/neural-model-catalog.test.ts; catalogEntryToModelPackage is pinned by the
// shared catalog-to-package.json fixture, which NeuralCatalogTest runs against this implementation.

internal data class CatalogFile(
    val role: String?,
    val path: String,
    val url: String,
    val sha256: String,
    val bytes: Long,
)

/** A licence as the catalog states it. The SDK's `License` keeps only `spdx` and `url`; the demo shows all of it. */
internal data class CatalogLicense(
    val spdx: String?,
    val url: String?,
    val restrictions: String?,
    val attribution: String?,
)

internal data class CatalogVoice(
    val id: String,
    val name: String,
    val locales: List<String>,
    val gender: String?,
    val file: CatalogFile,
    val license: CatalogLicense,
)

/** The runtime formats this app ships a runtime for. */
private val DEMO_RUNTIME_FORMATS = setOf("onnx")

internal data class CatalogEntry(
    val id: String,
    val variant: String,
    val version: String,
    val license: CatalogLicense,
    val reviewStatus: String,
    val reviewNotes: String?,
    val runtimeFormat: String,
    val minOsVersion: String?,
    val speechPipeline: String,
    val sampleRate: Long,
    val channels: Long,
    val graphs: Map<String, String>,
    val frontendKind: String,
    val frontendAssets: Map<String, String>,
    val files: List<CatalogFile>,
    val voices: List<CatalogVoice>,
) {
    /**
     * An entry the demo can download: it has files, is not left to a manual install, and its runtime
     * format is one this app ships a runtime for (Core AI is Apple-only).
     */
    val isInstallable: Boolean
        get() = reviewStatus != "manual_install" && files.isNotEmpty() && runtimeFormat in DEMO_RUNTIME_FORMATS

    /** Why an entry that is not installable cannot be downloaded here. */
    val unavailableReason: String
        get() = if (reviewStatus != "manual_install" && runtimeFormat !in DEMO_RUNTIME_FORMATS) {
            "the $runtimeFormat runtime is not available on Android"
        } else {
            reviewNotes ?: reviewStatus
        }

    /** Every file of the entry, weights first, then each voice bundle. */
    val allFiles: List<CatalogFile> get() = files + voices.map { it.file }

    val totalBytes: Long get() = allFiles.sumOf { it.bytes }

    /** Directory relative to `filesDir`: `voices-lab/<id>/<version>`. */
    val ref: String get() = "voices-lab/$id/$version"
}

internal object NeuralCatalogParser {
    fun parse(json: String): List<CatalogEntry> {
        val entries = JSONObject(json).getJSONArray("entries")
        return (0 until entries.length()).map { entry(entries.getJSONObject(it)) }
    }

    private fun entry(o: JSONObject): CatalogEntry {
        val speech = o.getJSONObject("speech")
        val runtime = o.getJSONObject("runtime")
        val review = o.getJSONObject("review")
        return CatalogEntry(
            id = o.getString("id"),
            variant = o.getString("variant"),
            version = o.getString("version"),
            license = license(o.getJSONObject("license")),
            reviewStatus = review.getString("status"),
            reviewNotes = review.optStringOrNull("notes"),
            runtimeFormat = runtime.getString("format"),
            minOsVersion = runtime.optStringOrNull("minOsVersion"),
            speechPipeline = speech.getString("pipeline"),
            sampleRate = speech.getLong("sampleRate"),
            channels = speech.getLong("channels"),
            graphs = stringMap(speech.getJSONObject("graphs")),
            frontendKind = speech.getJSONObject("frontend").getString("kind"),
            frontendAssets = stringMap(speech.getJSONObject("frontend").getJSONObject("assets")),
            files = o.optJSONArray("files").objects().map(::file),
            voices = o.optJSONArray("voices").objects().map(::voice),
        )
    }

    private fun voice(o: JSONObject) = CatalogVoice(
        id = o.getString("id"),
        name = o.getString("name"),
        locales = o.getJSONArray("locales").let { a -> (0 until a.length()).map { a.getString(it) } },
        gender = o.optStringOrNull("gender"),
        file = file(o.getJSONObject("file")),
        license = license(o.getJSONObject("license")),
    )

    private fun file(o: JSONObject) = CatalogFile(
        role = o.optStringOrNull("role"),
        path = o.getString("path"),
        url = o.getString("url"),
        sha256 = o.getString("sha256"),
        bytes = o.getLong("bytes"),
    )

    private fun license(o: JSONObject) = CatalogLicense(
        spdx = o.optStringOrNull("spdx"),
        url = o.optStringOrNull("url"),
        restrictions = o.optStringOrNull("restrictions"),
        attribution = o.optStringOrNull("attribution"),
    )

    private fun stringMap(o: JSONObject): Map<String, String> = o.keys().asSequence().associateWith { o.getString(it) }

    private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }

    private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)
}

/**
 * Turns an installed entry into the [ModelPackage] the neural speech provider takes: `app_managed`
 * at [ref], with `integrity.checksums` keyed by package path. The licence keeps `spdx` and `url`
 * (the contract has no field for `restrictions` or `attribution`).
 */
internal fun catalogEntryToModelPackage(entry: CatalogEntry, ref: String): ModelPackage = ModelPackage(
    format = requireNotNull(Format.fromRawValue(entry.runtimeFormat)) { "unknown format ${entry.runtimeFormat}" },
    id = entry.id,
    integrity = Integrity(checksums = entry.allFiles.associate { it.path to "sha256:${it.sha256}" }),
    license = License(spdx = entry.license.spdx, url = entry.license.url),
    runtime = entry.minOsVersion?.let { Runtime(minOsVersion = it) },
    source = Source(ref = ref, sourceType = SourceType.AppManaged),
    speech = SpeechModelPackage(
        channels = entry.channels,
        frontend = SpeechFrontend(
            assets = entry.frontendAssets,
            kind = requireNotNull(FrontendKind.fromRawValue(entry.frontendKind)),
        ),
        graphs = entry.graphs,
        pipeline = entry.speechPipeline,
        sampleRate = entry.sampleRate,
        voices = entry.voices.map { voice ->
            SpeechModelVoice(
                file = voice.file.path,
                gender = voice.gender?.let { VoiceGender.fromRawValue(it) },
                id = voice.id,
                license = AssetLicense(spdx = voice.license.spdx, url = voice.license.url),
                locales = voice.locales,
                name = voice.name,
            )
        },
    ),
    tasks = listOf("text_to_speech"),
    variant = entry.variant,
    version = entry.version,
)

/** Provider id the Android neural speech provider takes for a package: `<default id>:<package id>`. */
internal fun neuralProviderId(entryId: String): String = "${NeuralSpeechProvider.DEFAULT_ID}:$entryId"

/** The model profile requests name to reach an installed entry (never a model id). */
internal fun labProfileName(entryId: String): String = "voices-lab:$entryId"

/** The lab's profiles: per installed entry, `[neural provider, Android system speech]`. */
internal fun voicesLabProfiles(installedEntryIds: List<String>): Map<String, List<String>> = installedEntryIds.associate {
    labProfileName(it) to listOf(neuralProviderId(it), AndroidSystemSpeechProvider.DEFAULT_ID)
}
