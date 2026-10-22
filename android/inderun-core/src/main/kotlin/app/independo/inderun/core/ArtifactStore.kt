package app.independo.inderun.core

import app.independo.inderun.contracts.ArtifactLifetime
import app.independo.inderun.contracts.ArtifactOwner
import app.independo.inderun.contracts.ArtifactReadRequest
import app.independo.inderun.contracts.MediaArtifact
import java.io.ByteArrayOutputStream
import java.security.SecureRandom

/**
 * Size limits of an engine's artifact store (ADR 017). Every limit is in bytes.
 *
 * @property maxArtifactBytes Largest single artifact a provider may write. Default 16 MiB.
 * @property maxStoreBytes Most bytes the store holds across all undisposed artifacts. Default 64 MiB.
 * @property maxReadBytes Most bytes one `readArtifact` call returns. Default 1 MiB.
 */
data class ArtifactLimits(
    val maxArtifactBytes: Long = DEFAULT_MAX_ARTIFACT_BYTES,
    val maxStoreBytes: Long = DEFAULT_MAX_STORE_BYTES,
    val maxReadBytes: Long = DEFAULT_MAX_READ_BYTES,
) {
    companion object {
        const val DEFAULT_MAX_ARTIFACT_BYTES: Long = 16L * 1024 * 1024
        const val DEFAULT_MAX_STORE_BYTES: Long = 64L * 1024 * 1024
        const val DEFAULT_MAX_READ_BYTES: Long = 1024L * 1024
    }
}

/**
 * One range of an artifact's bytes, as `IndeRun.readArtifact` returns it.
 *
 * Compared by content: two chunks are equal when they carry the same bytes for the same range.
 *
 * @property artifactId The artifact the bytes belong to.
 * @property offset Byte offset of [bytes] within the artifact.
 * @property bytes The bytes of this range; empty when [offset] is the artifact's end. A copy the
 *   caller owns: changing it does not touch the stored artifact.
 * @property totalBytes Size of the whole artifact in bytes.
 * @property done Whether this range reaches the end of the artifact.
 */
class ArtifactChunk(
    val artifactId: String,
    val offset: Long,
    val bytes: ByteArray,
    val totalBytes: Long,
    val done: Boolean,
) {
    override fun equals(other: Any?): Boolean = other is ArtifactChunk &&
        artifactId == other.artifactId &&
        offset == other.offset &&
        totalBytes == other.totalBytes &&
        done == other.done &&
        bytes.contentEquals(other.bytes)

    override fun hashCode(): Int {
        var result = artifactId.hashCode()
        result = 31 * result + offset.hashCode()
        result = 31 * result + bytes.contentHashCode()
        result = 31 * result + totalBytes.hashCode()
        result = 31 * result + done.hashCode()
        return result
    }

    // Never the bytes themselves: artifact content is request-derived (ADR 017 §8).
    override fun toString(): String = "ArtifactChunk(artifactId=$artifactId, offset=$offset, length=${bytes.size}, " +
        "totalBytes=$totalBytes, done=$done)"
}

/**
 * What a provider declares when it starts writing an artifact.
 *
 * @property mediaType IANA media type of the bytes, e.g. `audio/wav`; parameters ride on it.
 * @property durationMs Duration of time-based media in milliseconds, where the provider knows it.
 */
data class ArtifactSpec(
    val mediaType: String,
    val durationMs: Double? = null,
)

/**
 * Writes one artifact into the engine's store. [finish] hands it over: it commits the run to the
 * provider and returns the reference the provider puts in its output. A provider that fails or
 * stops before [finish] calls [abort]; the engine also discards any writer an attempt left open.
 *
 * Safe to call from any thread, though one artifact's writes are expected in order.
 */
interface ArtifactWriter {
    /**
     * Appends a copy of [bytes]. Throws `Unavailable` (`details.code: "artifact_too_large"`) once
     * the artifact would exceed the engine's per-artifact limit, and discards what was written;
     * the attempt has not committed, so the run may fall back.
     */
    fun write(bytes: ByteArray)

    /**
     * Hands the finished artifact to the engine and commits the run. Throws `Unavailable`
     * (`artifact_store_full`) when the store has no room, and `Unavailable` (`run_not_active`)
     * when the run was cancelled or has ended -- in both cases before committing.
     */
    fun finish(): MediaArtifact

    /** Discards everything written. Idempotent. */
    fun abort()
}

/** Where a provider creates artifacts: [RunContext.artifacts] and [ProviderStreamContext.artifacts]. */
interface ArtifactSink {
    fun create(spec: ArtifactSpec): ArtifactWriter

    companion object {
        /**
         * A sink backed by a private store with default limits whose writers always commit: what a
         * context built outside an engine -- a provider's own unit test -- writes into.
         */
        fun standalone(): ArtifactSink = ArtifactStore().attempt { true }
    }
}

/**
 * The engine-owned, in-memory artifact store (ADR 017): one per `IndeRun` instance. It holds every
 * finished artifact until the application disposes it; there are no temporary files, so nothing
 * outlives the process. Reads are ranged and bounded by [ArtifactLimits.maxReadBytes].
 *
 * Thread-safe: providers may write, and applications read and dispose, from any thread.
 */
class ArtifactStore(private val limits: ArtifactLimits = ArtifactLimits()) {
    private class StoredArtifact(val reference: MediaArtifact, val bytes: ByteArray)

    private val lock = Any()
    private val artifacts = HashMap<String, StoredArtifact>()
    private var storedBytes = 0L

    internal val maxArtifactBytes: Long get() = limits.maxArtifactBytes

    /**
     * Opens the artifacts of one attempt. [commit] is the attempt's commit hook; a writer's
     * [ArtifactWriter.finish] calls it, and refuses the handoff when it returns `false`.
     */
    fun attempt(commit: () -> Boolean): AttemptArtifacts = AttemptArtifacts(this, commit)

    /** Reads one range. See `IndeRunApi.readArtifact` for the contract. */
    fun read(request: ArtifactReadRequest): ArtifactChunk {
        val stored = synchronized(lock) { artifacts[request.artifactId] }
            ?: throw createUnavailable(
                message = "Artifact '${request.artifactId}' is not held by this engine.",
                retryable = false,
                details = mapOf("code" to "artifact_not_found"),
            )
        val totalBytes = stored.bytes.size.toLong()
        val offset = request.offset ?: 0L
        if (offset > totalBytes) {
            val issue = validationIssue("/offset", "offset $offset is beyond the artifact's $totalBytes bytes")
            throw createInternal(
                message = "Validation failed for ArtifactReadRequest: /offset - ${issue["message"]}",
                details = mapOf("validationIssues" to listOf(issue)),
            )
        }
        val length = minOf(request.maxBytes ?: limits.maxReadBytes, limits.maxReadBytes)
        val end = minOf(offset + length, totalBytes)
        return ArtifactChunk(
            artifactId = request.artifactId,
            offset = offset,
            // A copy: the caller may keep or mutate it without touching the stored bytes.
            bytes = stored.bytes.copyOfRange(offset.toInt(), end.toInt()),
            totalBytes = totalBytes,
            done = end == totalBytes,
        )
    }

    /** Releases an artifact's bytes. Idempotent; unknown ids are ignored. */
    fun dispose(artifactId: String) {
        synchronized(lock) {
            val stored = artifacts.remove(artifactId) ?: return
            storedBytes -= stored.bytes.size
        }
    }

    /** The stored reference for [artifactId], or null once it was disposed. */
    fun reference(artifactId: String): MediaArtifact? = synchronized(lock) { artifacts[artifactId]?.reference }

    /** Registers a finished artifact. Throws `Unavailable` (`artifact_store_full`) when it does not fit. */
    internal fun store(spec: ArtifactSpec, bytes: ByteArray): MediaArtifact = synchronized(lock) {
        if (storedBytes + bytes.size > limits.maxStoreBytes) {
            throw createUnavailable(
                message = "The engine's artifact store is full; dispose artifacts to free it.",
                details = mapOf("code" to "artifact_store_full"),
            )
        }
        val reference = MediaArtifact(
            id = "art_${randomId()}",
            mediaType = spec.mediaType,
            owner = ArtifactOwner.Engine,
            lifetime = ArtifactLifetime.UntilDisposed,
            byteLength = bytes.size.toLong(),
            durationMs = spec.durationMs,
        )
        artifacts[reference.id] = StoredArtifact(reference, bytes)
        storedBytes += bytes.size
        reference
    }

    private companion object {
        val random = SecureRandom()

        fun randomId(): String {
            val bytes = ByteArray(12)
            random.nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }
    }
}

/**
 * The artifacts one attempt created. The engine keeps the one the attempt returned and releases
 * the rest: everything from an attempt that failed, was cancelled or lost to fallback, and anything
 * a winning attempt finished but did not return. A returned artifact is never released behind the
 * application's back.
 *
 * Thread-safe. Once [release] ran, the attempt is over: a writer that finishes afterwards -- a
 * provider still working on a thread of its own -- is refused like a refused commit.
 */
class AttemptArtifacts internal constructor(
    private val store: ArtifactStore,
    private val commit: () -> Boolean,
) : ArtifactSink {
    private val lock = Any()
    private val finished = LinkedHashSet<String>()
    private val open = LinkedHashSet<Writer>()
    private var released = false

    override fun create(spec: ArtifactSpec): ArtifactWriter {
        val writer = Writer(spec)
        synchronized(lock) { open += writer }
        return writer
    }

    /** Whether [artifactId] was finished by this attempt and is still held. */
    fun owns(artifactId: String): Boolean = synchronized(lock) { artifactId in finished } && store.reference(artifactId) != null

    /** Releases every artifact of this attempt except [keep], and closes open writers. */
    fun release(keep: String? = null) {
        val (writers, ids) = synchronized(lock) {
            released = true
            val snapshot = open.toList() to finished.toList()
            finished.clear()
            snapshot
        }
        writers.forEach { it.abort() }
        ids.filter { it != keep }.forEach { store.dispose(it) }
    }

    private fun runNotActive(): IndeRunException = createUnavailable(
        message = "The run is no longer active; the artifact was discarded.",
        details = mapOf("code" to "run_not_active"),
    )

    private inner class Writer(private val spec: ArtifactSpec) : ArtifactWriter {
        private var buffer: ByteArrayOutputStream? = ByteArrayOutputStream()

        override fun write(bytes: ByteArray) {
            synchronized(this) {
                val current = buffer ?: throw createInternal("The artifact writer is already closed.")
                if (current.size().toLong() + bytes.size > store.maxArtifactBytes) {
                    abort()
                    throw createUnavailable(
                        message = "The artifact exceeds the engine's ${store.maxArtifactBytes}-byte limit.",
                        details = mapOf("code" to "artifact_too_large"),
                    )
                }
                current.write(bytes)
            }
        }

        override fun finish(): MediaArtifact {
            val bytes = synchronized(this) {
                val current = buffer ?: throw createInternal("The artifact writer is already closed.")
                current.toByteArray().also { abort() }
            }
            if (synchronized(lock) { released }) throw runNotActive()
            // Stored before the commit so a full store fails the attempt pre-commit; dropped again
            // when the run refuses the commit.
            val reference = store.store(spec, bytes)
            if (!commit()) {
                store.dispose(reference.id)
                throw runNotActive()
            }
            val kept = synchronized(lock) { if (released) false else finished.add(reference.id) }
            if (!kept) {
                store.dispose(reference.id)
                throw runNotActive()
            }
            return reference
        }

        override fun abort() {
            synchronized(this) { buffer = null }
            synchronized(lock) { open -= this }
        }
    }
}

/** One validation issue as the engine reports it in `details.validationIssues`. */
private fun validationIssue(path: String, message: String): Map<String, String> = mapOf("path" to path, "message" to message)
