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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.LongBuffer
import java.security.MessageDigest

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
 * not referenced directly. [ModelPackage.integrity] checksums (`sha256:<hex>`) are verified for
 * every file this runtime resolves, before load.
 *
 * Decoding is **greedy (argmax) with no KV-cache reuse**: the full sequence is recomputed on every
 * generated token, CPU execution provider only. `generation.stop` sequences are honored;
 * `temperature`/`topP`/`seed` are not (no sampling, argmax only). This is a real, documented
 * performance limitation, not a hidden one. Chat formatting falls back to a plain `"role: content"`
 * join -- unlike the Apple/Web members, no chat-template application is attempted, since Hugging
 * Face chat-template support in the Android tokenizer binding is not guaranteed across models.
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

        val directory = resolveDirectory(modelPackage, sourceType)
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
            verifyChecksum(file, relativePath, modelPackage)
        }

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

        return LoadedSession(cacheKey = cacheKey, environment = ortEnvironment, session = session, tokenizer = tokenizer)
    }

    private fun resolveDirectory(modelPackage: ModelPackage, sourceType: SourceType): File {
        val ref = modelPackage.source?.ref
        return when (sourceType) {
            SourceType.Bundled -> {
                val relative = ref.orEmpty()
                val assetDir = File(context.filesDir, "inderun-onnx-assets/${modelPackage.id}")
                copyAssetDirectory(relative, assetDir)
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

    private fun copyAssetDirectory(assetPath: String, targetDir: File) {
        if (targetDir.exists() && targetDir.listFiles()?.isNotEmpty() == true) return
        targetDir.mkdirs()
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
                copyAssetDirectory(childAssetPath, File(targetDir, entry))
            }
        }
    }

    private fun verifyChecksum(file: File, relativePath: String, modelPackage: ModelPackage) {
        val expected = modelPackage.integrity?.checksums?.get(relativePath) ?: return
        val prefix = "sha256:"
        if (!expected.startsWith(prefix)) return

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
        val expectedHex = expected.removePrefix(prefix)
        if (!actual.equals(expectedHex, ignoreCase = true)) {
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "checksum/integrity mismatch: '$relativePath' does not match the expected checksum.",
            )
        }
    }

    private fun formatMessages(messages: List<AndroidOnnxGenerationMessage>): String = messages.joinToString(separator = "\n") { "${it.role.rawValue}: ${it.content}" }

    private fun decode(session: LoadedSession, prompt: String, input: AndroidOnnxGenerationInput): String {
        val maxNewTokens = (input.generation?.maxOutputTokens ?: DEFAULT_MAX_NEW_TOKENS).toInt()
        val stopSequences = input.generation?.stop.orEmpty()

        val encoding = session.tokenizer.encode(prompt)
        val ids = encoding.ids.toMutableList()
        val generatedIds = mutableListOf<Long>()

        repeat(maxNewTokens) {
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

            val decodedSoFar = session.tokenizer.decode(generatedIds.toLongArray())
            if (stopSequences.any { decodedSoFar.endsWith(it) }) {
                return@repeat
            }
        }

        return session.tokenizer.decode(generatedIds.toLongArray())
    }

    private fun argmaxLastToken(result: OrtSession.Result): Long {
        val logitsTensor = result.get("logits").orElseThrow {
            OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.INTERNAL_FAILURE,
                message = "model output malformed: session output does not contain a 'logits' tensor.",
            )
        } as OnnxTensor

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
    ) {
        fun close() {
            session.close()
            tokenizer.close()
        }
    }

    private companion object {
        const val DEFAULT_MAX_NEW_TOKENS = 256L
    }
}
