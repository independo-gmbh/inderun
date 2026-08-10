package app.independo.inderun.providers.onnx

import ai.djl.huggingface.tokenizers.HuggingFaceTokenizer
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import app.independo.inderun.contracts.FinishReason
import app.independo.inderun.contracts.Format
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.SourceType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.nio.LongBuffer
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/**
 * Production [AndroidOnnxGenAiRuntime] backed by ONNX Runtime Mobile
 * (`com.microsoft.onnxruntime:onnxruntime-android`) and a Hugging Face tokenizer
 * (`ai.djl.huggingface:tokenizers`).
 *
 * **IO contract**: the model graph must expose exactly `input_ids` and `attention_mask` inputs
 * (`int64`, `[1, sequenceLength]`) and a `logits` output (`float32`, `[1, sequenceLength,
 * vocabSize]`) -- the plain decoder-only export shape, without `past_key_values`. This mirrors the
 * Apple member's `SystemOnnxGenAiRuntime`.
 *
 * **Graph file convention**: [ModelPackage.files]'s `required` list has no positional semantics of
 * its own in the schema, so this runtime defines one -- the *first* entry is the ONNX graph file;
 * any remaining entries (for example external weight shards) must be present alongside it but are
 * not referenced directly. Every file named in [ModelPackage.integrity]'s checksum map is verified
 * (`sha256:<hex>` only; any other algorithm prefix is a capability failure, not a silently skipped
 * check), before load.
 *
 * **Stop conditions.** Generation stops on the tokenizer's end-of-sequence token (resolved from the
 * model config JSON's `eos_token_id`, since the DJL tokenizer binding does not expose it directly),
 * on a `generation.stop` suffix match, or once `generation.maxOutputTokens` tokens have been
 * produced -- whichever comes first. Coroutine cancellation is checked before every decode step
 * (`cancel: soft`: `OrtSession.run()` itself cannot be interrupted mid-call).
 *
 * Decoding is **greedy (argmax) with no KV-cache reuse**: the full sequence is recomputed on every
 * generated token, CPU execution provider only. `temperature`/`topP`/`seed` are not honored (no
 * sampling, argmax only). This is a real, documented performance limitation, not a hidden one. Chat
 * formatting falls back to a plain `"role: content"` join -- unlike the Apple/Web members, no
 * chat-template application is attempted, since Hugging Face chat-template support in the Android
 * tokenizer binding is not guaranteed across models.
 *
 * **Bundled asset extraction.** `bundled` sources are copied from Android assets into app-private
 * storage under a directory keyed by the session cache key (id/format/version/source/checksums), so
 * a changed `version`/`ref`/checksum extracts into a fresh directory rather than silently reusing
 * stale bytes. Extraction is atomic (copied into a temp directory, marked complete, then moved into
 * place) so an interrupted copy cannot poison a later load.
 *
 * `programmatic` model sources are out of scope for this default runtime (no files to resolve,
 * matching the Web/Apple members' own `programmatic` carve-out); it reports *runtime package
 * unavailable* rather than throwing. This default runtime has not been run against a real model
 * on-device -- real-device verification is tracked alongside the Apple member's own follow-up.
 */
class SystemAndroidOnnxGenAiRuntime(private val context: Context) : AndroidOnnxGenAiRuntime {

    private val sessionMutex = Mutex()
    private var cachedSession: LoadedSession? = null

    override suspend fun prepare(modelPackage: ModelPackage): AndroidOnnxRuntimeAvailability = try {
        withContext(Dispatchers.IO) { loadSession(modelPackage) }
        AndroidOnnxRuntimeAvailability(available = true)
    } catch (error: CancellationException) {
        throw error
    } catch (error: OnnxRuntimeError) {
        AndroidOnnxRuntimeAvailability(available = false, reason = error.message)
    } catch (error: Throwable) {
        AndroidOnnxRuntimeAvailability(
            available = false,
            reason = "runtime initialization failed: ${error.localizedMessage ?: error}",
        )
    }

    override suspend fun generate(input: AndroidOnnxGenerationInput): AndroidOnnxGenerationOutput = withContext(Dispatchers.Default) {
        val session = withContext(Dispatchers.IO) { loadSession(input.modelPackage) }
        val prompt = formatMessages(input.messages)
        val text = decode(session, prompt, input)
        AndroidOnnxGenerationOutput(text = text, finishReason = FinishReason.STOP)
    }

    private suspend fun loadSession(modelPackage: ModelPackage): LoadedSession = sessionMutex.withLock {
        val cacheKey = sessionCacheKey(modelPackage)
        cachedSession?.takeIf { it.cacheKey == cacheKey }?.let { return it }

        cachedSession?.close()
        cachedSession = null

        val loaded = openSession(modelPackage, cacheKey)
        cachedSession = loaded
        loaded
    }

    private fun openSession(modelPackage: ModelPackage, cacheKey: String): LoadedSession {
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

        val ortEnvironment = OrtEnvironment.getEnvironment()
        val session = try {
            ortEnvironment.createSession(graphFile.absolutePath, OrtSession.SessionOptions())
        } catch (error: Throwable) {
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.UNAVAILABLE,
                message = "runtime initialization failed: unable to create an ONNX Runtime session for " +
                    "'${modelPackage.id}'.",
                originalError = error,
            )
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
            environment = ortEnvironment,
            session = session,
            tokenizer = tokenizer,
            eosTokenId = eosTokenId,
        )
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
     * that this runtime did not resolve a path for are skipped (mirrors the Apple member); an
     * unsupported checksum algorithm is a capability failure rather than a silently skipped check.
     */
    private fun verifyChecksums(directory: File, modelPackage: ModelPackage) {
        val checksums = modelPackage.integrity?.checksums ?: return
        for ((relativePath, expected) in checksums) {
            val file = File(directory, relativePath)
            if (!file.exists()) continue
            verifyChecksum(file, relativePath, expected)
        }
    }

    private fun formatMessages(messages: List<AndroidOnnxGenerationMessage>): String = messages.joinToString(separator = "\n") { "${it.role.rawValue}: ${it.content}" }

    private suspend fun decode(session: LoadedSession, prompt: String, input: AndroidOnnxGenerationInput): String {
        val maxNewTokens = (input.generation?.maxOutputTokens ?: DEFAULT_MAX_NEW_TOKENS).toInt()
        val stopSequences = input.generation?.stop.orEmpty().filter { it.isNotEmpty() }

        val encoding = session.tokenizer.encode(prompt)
        val ids = encoding.ids.toMutableList()
        val generatedIds = mutableListOf<Long>()
        var matchedStop: String? = null

        while (generatedIds.size < maxNewTokens) {
            coroutineContext.ensureActive()

            val sequenceLength = ids.size
            val inputIds = LongBuffer.wrap(ids.toLongArray())
            val attentionMask = LongBuffer.wrap(LongArray(sequenceLength) { 1L })
            val shape = longArrayOf(1, sequenceLength.toLong())

            val nextTokenId = OnnxTensor.createTensor(session.environment, inputIds, shape).use { inputIdsTensor ->
                OnnxTensor.createTensor(session.environment, attentionMask, shape).use { attentionMaskTensor ->
                    session.session.run(
                        mapOf("input_ids" to inputIdsTensor, "attention_mask" to attentionMaskTensor),
                    ).use { result ->
                        argmaxLastToken(result)
                    }
                }
            }

            ids += nextTokenId
            generatedIds += nextTokenId

            if (isEosToken(nextTokenId, session.eosTokenId)) {
                break
            }

            val decodedSoFar = session.tokenizer.decode(generatedIds.toLongArray(), true)
            val stop = matchStopSequence(decodedSoFar, stopSequences)
            if (stop != null) {
                matchedStop = stop
                break
            }
        }

        var text = session.tokenizer.decode(generatedIds.toLongArray(), true)
        if (matchedStop != null && text.endsWith(matchedStop)) {
            text = text.removeSuffix(matchedStop)
        }
        return text
    }

    private fun argmaxLastToken(result: OrtSession.Result): Long {
        val logitsTensor = result.get("logits").orElseThrow {
            OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.INTERNAL_FAILURE,
                message = "model output malformed: session output does not contain a 'logits' tensor.",
            )
        } as OnnxTensor

        @Suppress("UNCHECKED_CAST")
        val logits = logitsTensor.value as Array<Array<FloatArray>>
        val lastStepLogits = logits[0].last()
        var bestIndex = 0
        var bestValue = Float.NEGATIVE_INFINITY
        for (index in lastStepLogits.indices) {
            if (lastStepLogits[index] > bestValue) {
                bestValue = lastStepLogits[index]
                bestIndex = index
            }
        }
        return bestIndex.toLong()
    }

    /**
     * Resolves the tokenizer's end-of-sequence token id from the model config JSON's
     * `eos_token_id` field (a plain integer, or the first entry when the field is a list, per the
     * Hugging Face `config.json` convention). The DJL tokenizer binding does not expose special
     * token ids directly, unlike `swift-transformers` on Apple, so this runtime reads the config
     * file itself. Absence of a resolvable config or field means generation relies solely on
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

    private fun sessionCacheKey(modelPackage: ModelPackage): String {
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

    private data class LoadedSession(
        val cacheKey: String,
        val environment: OrtEnvironment,
        val session: OrtSession,
        val tokenizer: HuggingFaceTokenizer,
        val eosTokenId: Long?,
    ) {
        fun close() {
            session.close()
            tokenizer.close()
        }
    }

    private companion object {
        const val DEFAULT_MAX_NEW_TOKENS = 256L
        const val EXTRACTION_COMPLETE_MARKER = ".inderun-onnx-extraction-complete"
    }
}

/** Whether the just-generated token is the tokenizer's end-of-sequence token. */
internal fun isEosToken(tokenId: Long, eosTokenId: Long?): Boolean = eosTokenId != null && tokenId == eosTokenId

/** Returns the first `generation.stop` sequence the decoded-so-far text ends with, or `null`. */
internal fun matchStopSequence(decodedSoFar: String, stopSequences: List<String>): String? = stopSequences.firstOrNull { decodedSoFar.endsWith(it) }

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

/** Short, filesystem-safe digest of a session cache key, used to key extracted-asset directories
 * so a changed model identity (version/source/checksums) extracts into a fresh directory instead
 * of reusing stale bytes copied under an older identity. */
internal fun cacheKeyDigest(cacheKey: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(cacheKey.toByteArray(Charsets.UTF_8))
    return digest.joinToString(separator = "") { "%02x".format(it) }.take(16)
}
