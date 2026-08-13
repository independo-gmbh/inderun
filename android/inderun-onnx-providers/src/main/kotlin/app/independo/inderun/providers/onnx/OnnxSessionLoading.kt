package app.independo.inderun.providers.onnx

import ai.djl.huggingface.tokenizers.HuggingFaceTokenizer
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtException
import ai.onnxruntime.OrtSession
import android.content.Context
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.SourceType
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * A tokenizer + ORT session resolved and loaded for a specific model package, plus the decode
 * strategy auto-detected from the graph's declared input names at load time.
 */
internal data class LoadedSession(
    val cacheKey: String,
    val environment: OrtEnvironment,
    val session: OrtSession,
    val tokenizer: HuggingFaceTokenizer,
    val eosTokenId: Long?,
    val decodeStrategy: DecodeStrategy,
) {
    fun close() {
        session.close()
        tokenizer.close()
    }
}

/**
 * Lazily resolves and caches the loaded session for the most recently requested model package, so
 * repeated `prepare`/`generate` calls do not reload the model and tokenizer every time. A changed
 * `version`/`ref`/checksum evicts the stale session rather than silently reusing it.
 */
internal class LoadedSessionBox(private val context: Context) {
    private val mutex = Mutex()
    private var cached: LoadedSession? = null

    suspend fun loaded(modelPackage: ModelPackage): LoadedSession = mutex.withLock {
        val cacheKey = sessionCacheKey(modelPackage)
        cached?.takeIf { it.cacheKey == cacheKey }?.let { return it }

        cached?.close()
        cached = null

        val loaded = withContext(OnnxExecutionDispatcher.dispatcher) { load(modelPackage, cacheKey) }
        cached = loaded
        loaded
    }

    private fun load(modelPackage: ModelPackage, cacheKey: String): LoadedSession {
        if (modelPackage.format != Format.Onnx && modelPackage.format != Format.Ort) {
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "unsupported model format: '${modelPackage.format}' is not supported by the " +
                    "Android ONNX Runtime member (expected 'onnx' or 'ort').",
            )
        }

        val sourceType = modelPackage.source?.sourceType
            ?: throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model source unavailable: no model source was configured.",
            )

        val directory = resolveDirectory(modelPackage, sourceType, cacheKey)
        val requiredFiles = modelPackage.files?.required.orEmpty()
        if (requiredFiles.isEmpty()) {
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model files missing: model package '${modelPackage.id}' declares no required files.",
            )
        }

        val graphFile = File(directory, requiredFiles.first())
        requiredFiles.forEach { relativePath ->
            val file = File(directory, relativePath)
            if (!file.exists()) {
                throw OnnxRuntimeError(
                    kind = OnnxRuntimeErrorKind.CAPABILITY,
                    message = "model files missing: '$relativePath' not found at ${file.absolutePath}.",
                )
            }
        }
        verifyChecksums(directory, modelPackage)

        val tokenizerFile = modelPackage.files?.tokenizer?.let { File(directory, it) }

        val environment = OrtEnvironment.getEnvironment()
        var session = makeSession(environment, graphFile, useNnapi = true)
        val decodeStrategy = detectDecodeStrategy(session, directory)

        // NNAPI's behavior on the KV-cache path's genuinely zero-length initial `past_key_values`
        // tensor is unverified on-device (see #88); the Apple member's CoreML EP rejects an
        // analogous zero-length dynamic-shaped input at run time, so the KV-cache path
        // conservatively never uses NNAPI here either, on the same reasoning, not a confirmed
        // Android-device finding. Re-creating the session is the only option: the execution
        // provider list is fixed at session-creation time.
        if (decodeStrategy is DecodeStrategy.KvCache) {
            session.close()
            session = makeSession(environment, graphFile, useNnapi = false)
        }

        val tokenizer = try {
            if (tokenizerFile != null && tokenizerFile.exists()) {
                HuggingFaceTokenizer.newInstance(tokenizerFile.toPath())
            } else {
                HuggingFaceTokenizer.newInstance(directory.toPath())
            }
        } catch (error: Throwable) {
            session.close()
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "tokenizer/config missing: unable to load a tokenizer for '${modelPackage.id}'.",
                originalError = error,
            )
        }

        val eosTokenId = resolveEosTokenId(directory, modelPackage)

        return LoadedSession(
            cacheKey = cacheKey,
            environment = environment,
            session = session,
            tokenizer = tokenizer,
            eosTokenId = eosTokenId,
            decodeStrategy = decodeStrategy,
        )
    }

    private fun makeSession(environment: OrtEnvironment, graphFile: File, useNnapi: Boolean): OrtSession = try {
        environment.createSession(graphFile.absolutePath, makeSessionOptions(useNnapi))
    } catch (error: Throwable) {
        throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.UNAVAILABLE,
            message = "runtime initialization failed: unable to create an ONNX Runtime session for " +
                "'${graphFile.name}'.",
            originalError = error,
        )
    }

    /**
     * Configures the NNAPI execution provider by default (when [useNnapi]), falling back to
     * XNNPACK and then ORT's default CPU EP if NNAPI configuration fails on this device/OS --
     * NNAPI's availability varies across hardware and Android versions, so this must degrade
     * rather than fail session creation. `useNnapi: false` skips straight to XNNPACK/CPU, for
     * graphs NNAPI cannot run at all (see the KV-cache zero-length-tensor note at this method's
     * call site). `intraOpNumThreads` is set explicitly (bounded by the device's available
     * processor count) rather than left at ORT's implicit default.
     */
    private fun makeSessionOptions(useNnapi: Boolean): OrtSession.SessionOptions {
        val options = OrtSession.SessionOptions()
        val threadCount = minOf(4, maxOf(1, Runtime.getRuntime().availableProcessors()))
        try {
            options.setIntraOpNumThreads(threadCount)
        } catch (error: OrtException) {
            // Falls back to ORT's implicit default thread count.
        }

        val nnapiEnabled = useNnapi && try {
            options.addNnapi()
            true
        } catch (error: OrtException) {
            false
        }
        if (!nnapiEnabled) {
            try {
                options.addXnnpack(mapOf("intra_op_num_threads" to threadCount.toString()))
            } catch (error: OrtException) {
                // Falls back to ORT's default CPU execution provider.
            }
        }
        return options
    }

    private fun resolveDirectory(modelPackage: ModelPackage, sourceType: SourceType, cacheKey: String): File {
        val ref = modelPackage.source?.ref
        return when (sourceType) {
            SourceType.Bundled -> {
                val relative = ref.orEmpty()
                val assetDir = File(
                    context.filesDir,
                    "inderun-onnx-assets/${modelPackage.id}/${cacheKeyDigest(cacheKey)}",
                )
                extractAssetDirectory(relative, assetDir)
                assetDir
            }
            SourceType.Filesystem -> {
                if (ref.isNullOrEmpty()) {
                    throw OnnxRuntimeError(
                        kind = OnnxRuntimeErrorKind.CAPABILITY,
                        message = "model source unavailable: a 'filesystem' model source requires 'source.ref'.",
                    )
                }
                File(ref)
            }
            SourceType.AppManaged -> {
                val base = context.filesDir
                if (ref.isNullOrEmpty()) base else File(base, ref)
            }
            SourceType.Programmatic -> throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "runtime package unavailable: 'programmatic' model sources have no files to " +
                    "resolve; supply a custom AndroidOnnxGenAiRuntime instead.",
            )
            SourceType.Registry, SourceType.Remote -> throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model source unavailable: '${sourceType.name.lowercase()}' model sources are " +
                    "deferred on Android.",
            )
        }
    }

    /**
     * Extracts a bundled asset directory into app-private storage exactly once per
     * [cacheKeyDigest], atomically: the copy lands in a sibling temp directory, a completion
     * marker is written last, and only then is the temp directory moved into place. A directory
     * missing the marker (never completed, or a previous run crashed mid-copy) is re-extracted
     * rather than trusted.
     */
    private fun extractAssetDirectory(assetPath: String, targetDir: File) {
        if (File(targetDir, EXTRACTION_COMPLETE_MARKER).exists()) return

        val tempDir = File(targetDir.parentFile, "${targetDir.name}.tmp-${System.nanoTime()}")
        tempDir.deleteRecursively()
        tempDir.mkdirs()
        try {
            copyAssetTree(assetPath, tempDir)
            val completionMarker = File(tempDir, EXTRACTION_COMPLETE_MARKER)
            if (!completionMarker.createNewFile()) {
                throw IllegalStateException(
                    "failed to create extraction completion marker '$EXTRACTION_COMPLETE_MARKER'.",
                )
            }
        } catch (error: Throwable) {
            tempDir.deleteRecursively()
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model source unavailable: failed to extract bundled model assets for '$assetPath'.",
                originalError = error,
            )
        }

        targetDir.deleteRecursively()
        if (!tempDir.renameTo(targetDir)) {
            tempDir.deleteRecursively()
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model source unavailable: failed to install extracted model assets for '$assetPath'.",
            )
        }
    }

    private fun copyAssetTree(assetPath: String, targetDir: File) {
        val assetManager = context.assets
        val entries = assetManager.list(assetPath).orEmpty()
        entries.forEach { entry ->
            val childAssetPath = if (assetPath.isEmpty()) entry else "$assetPath/$entry"
            val childEntries = assetManager.list(childAssetPath)
            if (childEntries.isNullOrEmpty()) {
                assetManager.open(childAssetPath).use { input ->
                    File(targetDir, entry).outputStream().use { output -> input.copyTo(output) }
                }
            } else {
                val childDir = File(targetDir, entry)
                childDir.mkdirs()
                copyAssetTree(childAssetPath, childDir)
            }
        }
    }

    /**
     * Verifies every file named in `integrity.checksums`, not only the required-file list, so a
     * checksum declared for the tokenizer or config file is enforced too. Files the map names but
     * that this runtime did not resolve a path for are skipped; an unsupported checksum algorithm
     * is a capability failure rather than a silently skipped check.
     */
    private fun verifyChecksums(directory: File, modelPackage: ModelPackage) {
        val checksums = modelPackage.integrity?.checksums ?: return
        for ((relativePath, expected) in checksums) {
            val file = File(directory, relativePath)
            if (!file.exists()) continue
            verifyChecksum(file, relativePath, expected)
        }
    }

    /**
     * Resolves the tokenizer's end-of-sequence token id from the model config JSON's
     * `eos_token_id` field. The DJL tokenizer binding does not expose special token ids directly,
     * unlike `swift-transformers` on Apple, so this runtime reads the config file itself. Absence
     * of a resolvable config or field means generation relies solely on
     * `generation.stop`/`maxOutputTokens`, not on EOS detection.
     */
    private fun resolveEosTokenId(directory: File, modelPackage: ModelPackage): Long? {
        val configFile = modelPackage.files?.config?.let { File(directory, it) }
            ?: File(directory, "config.json").takeIf { it.exists() }
            ?: return null
        if (!configFile.exists()) return null

        return try {
            parseEosTokenId(configFile.readText())
        } catch (error: Throwable) {
            null
        }
    }

    private companion object {
        const val EXTRACTION_COMPLETE_MARKER = ".inderun-onnx-extraction-complete"
    }
}

/**
 * Cache key covering everything that identifies *which bytes* this session was built from -- `id`
 * alone does not: an app can swap a bundled model file, change `source.ref`, or bump `version`
 * while keeping the same `id`, and a stale cached session would silently keep serving the old
 * model.
 */
internal fun sessionCacheKey(modelPackage: ModelPackage): String {
    val checksums = modelPackage.integrity?.checksums?.entries
        ?.sortedBy { it.key }
        ?.joinToString(separator = ",") { "${it.key}=${it.value}" }
        .orEmpty()
    return listOf(
        modelPackage.id,
        modelPackage.format.name,
        modelPackage.version.orEmpty(),
        modelPackage.source?.sourceType?.name.orEmpty(),
        modelPackage.source?.ref.orEmpty(),
        checksums,
    ).joinToString(separator = "|")
}

/**
 * Verifies a single resolved file against a `algorithm:hex` checksum string. Only `sha256` is
 * supported; any other algorithm prefix is a capability failure rather than a silently skipped
 * check, since the schema permits arbitrary non-empty checksum strings and a configured-but-unknown
 * algorithm must not be mistaken for "no integrity check requested".
 */
internal fun verifyChecksum(file: File, relativePath: String, expected: String) {
    val prefix = "sha256:"
    if (!expected.startsWith(prefix, ignoreCase = true)) {
        throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.CAPABILITY,
            message = "checksum/integrity mismatch: unsupported checksum algorithm for '$relativePath' " +
                "(only 'sha256:<hex>' is supported).",
        )
    }

    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var read = input.read(buffer)
        while (read >= 0) {
            digest.update(buffer, 0, read)
            read = input.read(buffer)
        }
    }
    val actual = digest.digest().joinToString(separator = "") { "%02x".format(it) }
    val expectedHex = expected.substring(prefix.length)
    if (!actual.equals(expectedHex, ignoreCase = true)) {
        throw OnnxRuntimeError(
            kind = OnnxRuntimeErrorKind.CAPABILITY,
            message = "checksum/integrity mismatch: '$relativePath' does not match the expected checksum.",
        )
    }
}

/**
 * Extracts `eos_token_id` from a Hugging Face-style `config.json` payload. The field is either a
 * plain integer or a list of integers (some model configs declare multiple eos candidates); the
 * first value is used either way. Returns `null` when the field is absent or malformed.
 */
internal fun parseEosTokenId(configJson: String): Long? {
    val json = JSONObject(configJson)
    if (!json.has("eos_token_id")) return null

    val value = json.get("eos_token_id")
    return when (value) {
        is Int -> value.toLong()
        is Long -> value
        is org.json.JSONArray -> if (value.length() > 0) value.getLong(0) else null
        else -> null
    }
}

/**
 * Short, filesystem-safe digest of a session cache key, used to key extracted-asset directories so
 * a changed model identity (version/source/checksums) extracts into a fresh directory instead of
 * reusing stale bytes copied under an older identity.
 */
internal fun cacheKeyDigest(cacheKey: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(cacheKey.toByteArray(Charsets.UTF_8))
    return digest.joinToString(separator = "") { "%02x".format(it) }.take(16)
}
