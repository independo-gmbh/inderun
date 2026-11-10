package app.independo.inderun.demo

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/** What the person accepts before a single byte is requested. */
internal data class ConsentPrompt(
    val entry: CatalogEntry,
    val totalBytes: Long,
    /** One line per licence: the model's, its attribution, and each distinct voice licence. */
    val licenses: List<String>,
)

internal sealed interface NeuralDownloadResult {
    data object Installed : NeuralDownloadResult

    data object Declined : NeuralDownloadResult
}

internal class NeuralDownloadException(message: String, cause: Throwable? = null) : Exception(message, cause)

internal class TransportResponse(val status: Int, val body: InputStream?, private val onClose: () -> Unit = {}) : AutoCloseable {
    override fun close() {
        runCatching { body?.close() }
        onClose()
    }
}

/**
 * Lets a blocked [NeuralTransport.open] be aborted from another thread. The action registered last
 * runs on [cancel]; one registered after [cancel] runs at once, so a cancel never goes unseen.
 */
internal class TransportCancellation {
    private var action: (() -> Unit)? = null
    private var cancelled = false

    fun onCancel(action: () -> Unit) {
        val runNow = synchronized(this) {
            if (!cancelled) this.action = action
            cancelled
        }
        if (runNow) action()
    }

    fun cancel() {
        val pending = synchronized(this) {
            cancelled = true
            action.also { action = null }
        }
        pending?.invoke()
    }
}

/** The one place the network is touched, so tests can count requests. */
internal fun interface NeuralTransport {
    fun open(url: String): TransportResponse

    /**
     * Blocks until the response status is known; [cancellation] aborts the call from another
     * thread (a stalled DNS, TLS or server-response step does not see coroutine cancellation).
     */
    fun open(url: String, cancellation: TransportCancellation): TransportResponse = open(url)
}

/** Direct fetch of Hugging Face files and GitHub release assets (no proxy); redirects are followed. */
internal object UrlConnectionTransport : NeuralTransport {
    override fun open(url: String): TransportResponse = open(url, TransportCancellation())

    override fun open(url: String, cancellation: TransportCancellation): TransportResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.setRequestProperty("User-Agent", "IndeRunDemo/1.0")
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        // Disconnecting from another thread makes the blocked responseCode below throw.
        cancellation.onCancel(connection::disconnect)
        val status = connection.responseCode
        return TransportResponse(
            status = status,
            body = if (status in 200..299) connection.inputStream else null,
            onClose = connection::disconnect,
        )
    }
}

internal fun consentPrompt(entry: CatalogEntry): ConsentPrompt {
    val lines = mutableListOf<String>()
    val restrictions = entry.license.restrictions?.takeIf { it != "none" }
    lines += (entry.license.spdx ?: "unspecified licence") + (restrictions?.let { ": $it" } ?: "")
    entry.license.attribution?.let { lines += it }
    for (voice in entry.voices) {
        val line = "${voice.license.spdx ?: "voice licence"}: ${voice.license.restrictions.orEmpty()}"
        if (line !in lines) lines += line
    }
    return ConsentPrompt(entry, entry.totalBytes, lines)
}

/**
 * Installs every file of a catalog entry (weights and voices) under
 * `<root>/voices-lab/<id>/<version>/`, which is where an `app_managed` package resolves its `ref`
 * (`root` is `context.filesDir`). Nothing is created or requested before the person consents.
 *
 * A file is streamed to `<name>.part`, hashed on the way, and only renamed into place once its
 * byte count and sha256 match, so a half-written file is never accepted. A mismatch deletes the
 * file and fails with `checksum mismatch: <path>`; a failure leaves only verified files behind, so
 * a retry resumes by skipping them.
 */
internal class DemoNeuralModelDownloader(
    private val root: File,
    private val transport: NeuralTransport = UrlConnectionTransport,
    private val openOutput: (File) -> OutputStream = { it.outputStream() },
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    fun directory(entry: CatalogEntry): File = File(root, entry.ref)

    /** Read-only: creates nothing. True when every file is present with its size and sha256. */
    suspend fun isInstalled(entry: CatalogEntry): Boolean = withContext(io) {
        entry.isInstallable && entry.allFiles.all { isVerified(File(directory(entry), it.path), it) }
    }

    suspend fun download(
        entry: CatalogEntry,
        consent: suspend (ConsentPrompt) -> Boolean,
        onProgress: (doneBytes: Long, totalBytes: Long) -> Unit = { _, _ -> },
    ): NeuralDownloadResult {
        val prompt = consentPrompt(entry)
        if (!consent(prompt)) return NeuralDownloadResult.Declined
        withContext(io) {
            var done = 0L
            for (file in entry.allFiles) {
                val destination = File(directory(entry), file.path)
                if (isVerified(destination, file)) {
                    done += file.bytes
                    onProgress(done, prompt.totalBytes)
                    continue
                }
                // A stale or half-written file is never kept.
                // A file we cannot even remove is treated as absent; the write below reports the real problem.
                runCatching { destination.delete() }
                val base = done
                downloadFile(file, destination) { received -> onProgress(base + received, prompt.totalBytes) }
                done += file.bytes
            }
        }
        return NeuralDownloadResult.Installed
    }

    private suspend fun downloadFile(file: CatalogFile, destination: File, onBytes: (Long) -> Unit) {
        // Neither a blocked connect nor a blocked read sees coroutine cancellation, so a watcher aborts
        // the call on cancel: first the connection being established, then the response being read.
        val cancellation = TransportCancellation()
        coroutineScope {
            val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
                try {
                    awaitCancellation()
                } finally {
                    cancellation.cancel()
                }
            }
            try {
                val response = try {
                    transport.open(file.url, cancellation)
                } catch (error: IOException) {
                    // The abort on cancel is what ended the call: that is a cancel, not a failure.
                    coroutineContext.ensureActive()
                    throw NeuralDownloadException("download failed: ${file.path}: ${error.message}", error)
                }
                response.use {
                    cancellation.onCancel(response::close)
                    readBody(file, destination, response, onBytes)
                }
            } finally {
                watcher.cancel()
            }
        }
    }

    private suspend fun readBody(file: CatalogFile, destination: File, response: TransportResponse, onBytes: (Long) -> Unit) {
        run {
            val body = response.body
            if (body == null) {
                val published = file.url.startsWith("https://github.com/") && response.status == 404
                val reason = if (published) "asset not published yet" else "download failed"
                throw NeuralDownloadException("$reason (HTTP ${response.status}): ${file.path}")
            }
            val parent = destination.parentFile
            try {
                parent?.mkdirs()
            } catch (error: SecurityException) {
                throw storageFailure(file, IOException(error))
            }
            val part = File(parent, "${destination.name}.part")
            var finished = false
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                var received = 0L
                val output = try {
                    openOutput(part)
                } catch (error: IOException) {
                    throw storageFailure(file, error)
                }
                output.use {
                    val buffer = ByteArray(BUFFER_SIZE)
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = try {
                            body.read(buffer)
                        } catch (error: IOException) {
                            // Closing the response on cancel is what unblocked this read: that is a cancel, not a failure.
                            coroutineContext.ensureActive()
                            throw NeuralDownloadException("download failed: ${file.path}: ${error.message}", error)
                        }
                        if (read < 0) break
                        received += read
                        if (received > file.bytes) break
                        digest.update(buffer, 0, read)
                        try {
                            output.write(buffer, 0, read)
                        } catch (error: IOException) {
                            throw storageFailure(file, error)
                        }
                        onBytes(received)
                    }
                }
                if (received != file.bytes || digest.hex() != file.sha256) {
                    throw NeuralDownloadException("checksum mismatch: ${file.path}")
                }
                if (!part.renameTo(destination)) throw storageFailure(file, IOException("could not move into place"))
                finished = true
            } finally {
                if (!finished) part.delete()
            }
        }
    }

    /** Any IO or permission failure while checking means "not verified", so the file is fetched again. */
    private fun isVerified(target: File, file: CatalogFile): Boolean = try {
        if (!target.isFile || target.length() != file.bytes) {
            false
        } else {
            val digest = MessageDigest.getInstance("SHA-256")
            target.inputStream().use { input ->
                val buffer = ByteArray(BUFFER_SIZE)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            digest.hex() == file.sha256
        }
    } catch (_: IOException) {
        false
    } catch (_: SecurityException) {
        false
    }

    private fun storageFailure(file: CatalogFile, error: IOException): NeuralDownloadException {
        val full = error.message?.contains("ENOSPC", ignoreCase = true) == true ||
            error.message?.contains("no space", ignoreCase = true) == true
        return NeuralDownloadException(
            if (full) {
                "not enough storage space to save ${file.path}; free some space and try again"
            } else {
                "could not write ${file.path}: ${error.message}"
            },
            error,
        )
    }

    private fun MessageDigest.hex(): String = digest().joinToString("") { "%02x".format(it) }

    private companion object {
        const val BUFFER_SIZE = 64 * 1024
    }
}
