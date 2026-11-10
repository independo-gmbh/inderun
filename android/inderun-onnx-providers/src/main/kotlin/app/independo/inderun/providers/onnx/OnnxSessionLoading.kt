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
 * One cached value with a count of the callers using it. Retiring it releases the value only once
 * the last user has returned, so nothing ever runs on a released session.
 */
private class Lease<T>(val value: T, private val onRelease: (T) -> Unit) {
    private var users = 0
    private var retired = false
    private var released = false

    @Synchronized
    fun acquire() {
        users += 1
    }

    fun release() = settle { users -= 1 }

    fun retire() = settle { retired = true }

    private inline fun settle(change: () -> Unit) {
        val releaseNow = synchronized(this) {
            change()
            (retired && users == 0 && !released).also { if (it) released = true }
        }
        if (releaseNow) onRelease(value)
    }
}

/**
 * Caches the value loaded for the most recently requested key, and releases what it drops only once
 * the callers using it have returned. A different key evicts the cached value. [close] drops the
 * cached value without suspending, and a later [use] loads again. A load still running when [close]
 * is called is not cached: its value is released once its caller is done with it.
 */
internal class LeasedCache<T>(private val onRelease: (T) -> Unit) {
    /** Serializes loading, so concurrent callers load one key once. */
    private val mutex = Mutex()

    /** Guards [cached] and [epoch], which [close] changes without suspending. */
    private val lock = Any()
    private var cached: Pair<String, Lease<T>>? = null

    /** Bumped by [close], so a load that started before it does not cache its value. */
    private var epoch = 0

    /** Runs [block] with the value cached for [key], loading it with [load] first when needed. */
    suspend fun <R> use(key: String, load: suspend () -> T, block: suspend (T) -> R): R {
        val lease = acquire(key, load)
        try {
            return block(lease.value)
        } finally {
            lease.release()
        }
    }

    /** Drops the cached value; idempotent, never throws, never suspends. */
    fun close() {
        synchronized(lock) {
            epoch += 1
            cached?.second?.retire()
            cached = null
        }
    }

    private suspend fun acquire(key: String, load: suspend () -> T): Lease<T> = mutex.withLock {
        val startEpoch = synchronized(lock) {
            val current = cached
            if (current != null && current.first == key) {
                current.second.acquire()
                return current.second
            }
            current?.second?.retire()
            cached = null
            epoch
        }

        val lease = Lease(load(), onRelease)
        lease.acquire()
        synchronized(lock) {
            if (epoch == startEpoch) cached = key to lease else lease.retire()
        }
        lease
    }
}

/**
 * Lazily resolves and caches the loaded session for the most recently requested model package, so
 * repeated `prepare`/`generate` calls do not reload the model and tokenizer every time. A changed
 * `version`/`ref`/checksum evicts the stale session rather than silently reusing it.
 *
 * A session the cache drops (on eviction or [close]) is closed on the execution thread once the
 * generations using it have returned: an ORT session and the tokenizer hold native memory the
 * garbage collector does not free.
 */
internal class LoadedSessionBox(context: Context) {
    private val directories = OnnxModelDirectory(context)
    private val cache = LeasedCache<LoadedSession> { closeOnExecutionThread(listOf(it::close)) }

    /** Loads the package's session (or reuses the cached one) and runs [block] with it. */
    suspend fun <R> use(modelPackage: ModelPackage, block: suspend (LoadedSession) -> R): R {
        val cacheKey = sessionCacheKey(modelPackage)
        return cache.use(
            key = cacheKey,
            load = { withContext(OnnxExecutionDispatcher.dispatcher) { load(modelPackage, cacheKey) } },
            block = block,
        )
    }

    /** Drops the cached session; see the class documentation. */
    fun close() = cache.close()

    /**
     * Checks what can be checked without loading, cheaply enough for the capability check, which
     * runs on every request. Bundled files stay unchecked: reaching them means extracting them.
     */
    fun check(modelPackage: ModelPackage) {
        val sourceType = checkedSourceType(modelPackage)
        val requiredFiles = checkedRequiredFiles(modelPackage)
        if (sourceType != SourceType.Bundled) {
            val directory = directories.resolve(modelPackage, sourceType, sessionCacheKey(modelPackage))
            directories.checkFilesExist(directory, requiredFiles)
        }
    }

    private fun checkedSourceType(modelPackage: ModelPackage): SourceType {
        if (modelPackage.format != Format.Onnx && modelPackage.format != Format.Ort) {
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "unsupported model format: '${modelPackage.format}' is not supported by the " +
                    "Android ONNX Runtime member (expected 'onnx' or 'ort').",
            )
        }

        return modelPackage.source?.sourceType
            ?: throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model source unavailable: no model source was configured.",
            )
    }

    private fun checkedRequiredFiles(modelPackage: ModelPackage): List<String> {
        val requiredFiles = modelPackage.files?.required.orEmpty()
        if (requiredFiles.isEmpty()) {
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model files missing: model package '${modelPackage.id}' declares no required files.",
            )
        }
        return requiredFiles
    }

    private fun load(modelPackage: ModelPackage, cacheKey: String): LoadedSession {
        val sourceType = checkedSourceType(modelPackage)
        val directory = directories.resolve(modelPackage, sourceType, cacheKey)
        val requiredFiles = checkedRequiredFiles(modelPackage)
        val graphFile = File(directory, requiredFiles.first())
        directories.checkFilesExist(directory, requiredFiles)
        directories.verifyChecksums(directory, modelPackage)

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

        val nnapiEnabled = if (!useNnapi) {
            false
        } else {
            try {
                options.addNnapi()
                true
            } catch (error: OrtException) {
                false
            }
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
