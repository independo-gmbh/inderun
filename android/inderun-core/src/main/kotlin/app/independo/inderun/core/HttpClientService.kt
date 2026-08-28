package app.independo.inderun.core

import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.job
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL

/**
 * Default normalized HTTP transport backed by [HttpURLConnection].
 */
class URLConnectionHttpClientService : HttpClientService {
    override suspend fun send(request: HttpRequest): HttpResponse = withContext(Dispatchers.IO) {
        val connection = (URL(request.url).openConnection() as? HttpURLConnection)
            ?: throw createInternal("HTTP transport could not open an HttpURLConnection.")

        currentCoroutineContext().ensureActive()
        currentCoroutineContext().job.invokeOnCompletion { connection.disconnect() }

        try {
            connection.requestMethod = request.method.name.uppercase()
            connection.instanceFollowRedirects = true
            connection.doInput = true

            request.timeoutMs?.let { timeoutMs ->
                val timeout = timeoutMs.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
                connection.connectTimeout = timeout
                connection.readTimeout = timeout
            }

            request.headers?.forEach { (key, value) ->
                connection.setRequestProperty(key, value)
            }

            val requestBody = request.body
            if (requestBody != null) {
                connection.doOutput = true
                connection.outputStream.use { output ->
                    output.write(requestBody.toByteArray(Charsets.UTF_8))
                }
            }

            val status = connection.responseCode.toLong()
            val statusText = connection.responseMessage ?: ""
            val headers = connection.headerFields.orEmpty()
                .filterKeys { it != null }
                .mapValues { (_, values) -> values.joinToString(", ") }

            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream.readFully()

            HttpResponse(
                body = body,
                headers = headers,
                status = status,
                statusText = statusText,
            )
        } finally {
            connection.disconnect()
        }
    }
}

/**
 * Default normalized streaming HTTP transport backed by [HttpURLConnection].
 *
 * The connection is opened and the response head read eagerly in [stream]; the
 * body stays unread until the returned [Flow] is collected, and the connection
 * is released when collection completes, fails, or is cancelled.
 */
class URLConnectionStreamingHttpClientService : HttpStreamingClientService {
    override suspend fun stream(request: HttpRequest): HttpStreamResponse = withContext(Dispatchers.IO) {
        val connection = (URL(request.url).openConnection() as? HttpURLConnection)
            ?: throw createInternal("HTTP transport could not open an HttpURLConnection.")

        currentCoroutineContext().ensureActive()

        val head = try {
            connection.requestMethod = request.method.name.uppercase()
            connection.instanceFollowRedirects = true
            connection.doInput = true

            request.timeoutMs?.let { timeoutMs ->
                val timeout = timeoutMs.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
                connection.connectTimeout = timeout
                // HttpURLConnection fixes the socket read deadline at connect
                // time, so this one value has to serve two purposes: it bounds
                // the wait for the response head, and it becomes the polling
                // interval for the body, where a read that expires means "no
                // data yet" rather than a failure (see [chunks]).
                connection.readTimeout = timeout
            }

            request.headers?.forEach { (key, value) ->
                connection.setRequestProperty(key, value)
            }

            val requestBody = request.body
            if (requestBody != null) {
                connection.doOutput = true
                connection.outputStream.use { output ->
                    output.write(requestBody.toByteArray(Charsets.UTF_8))
                }
            }

            val status = connection.responseCode.toLong()
            val statusText = connection.responseMessage ?: ""
            // Lower-cased so header lookups are case-insensitive at the call
            // site; HttpURLConnection also reports the status line under a
            // null key, which is dropped here.
            val headers = connection.headerFields.orEmpty()
                .filterKeys { it != null }
                .map { (key, values) -> key.lowercase() to values.joinToString(", ") }
                .toMap()

            Triple(status, statusText, headers)
        } catch (throwable: Throwable) {
            connection.disconnect()
            if (throwable is SocketTimeoutException) {
                throw createTimeout("HTTP transport timed out waiting for the response head.")
            }
            throw throwable
        }

        val (status, statusText, headers) = head

        val stream = if (status in 200..299) connection.inputStream else connection.errorStream

        HttpStreamResponse(
            status = status,
            statusText = statusText,
            headers = headers,
            body = stream.chunks(connection).flowOn(Dispatchers.IO),
        )
    }

    private companion object {
        const val CHUNK_BYTES = 8 * 1024
    }

    private fun InputStream?.chunks(connection: HttpURLConnection): Flow<ByteArray> = flow {
        // ensureActive() alone cannot end a read that is already blocked waiting
        // for the next chunk, which is the normal state of an idle SSE stream.
        // Disconnecting from the canceller's thread closes the socket and makes
        // that read throw, so cancellation is observed immediately rather than
        // whenever the server next sends something.
        currentCoroutineContext().job.invokeOnCompletion { connection.disconnect() }

        val source = this@chunks ?: return@flow
        try {
            val input = source
            val buffer = ByteArray(CHUNK_BYTES)
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = try {
                    input.read(buffer)
                } catch (timeout: SocketTimeoutException) {
                    // An expired read on an established stream means the server
                    // has simply gone quiet, which is the normal state of a
                    // long-lived event stream and not a failure. Looping here is
                    // also what makes cancellation observable: a blocked socket
                    // read cannot be interrupted from another thread reliably —
                    // HttpURLConnection.disconnect() is documented as best
                    // effort — so the read has to come back on its own before
                    // ensureActive() can end the collection. Cancellation
                    // latency is therefore bounded by timeoutMs; without one,
                    // the read blocks until the server speaks again.
                    continue
                } catch (error: IOException) {
                    // Tearing down the connection to release a cancelled
                    // collection surfaces as an IO failure on the reading
                    // thread. If this coroutine is already cancelled, that
                    // failure *is* the cancellation, and reporting it as a
                    // transport error would turn an orderly cancel into a
                    // spurious stream failure.
                    currentCoroutineContext().ensureActive()
                    throw error
                }
                if (read == -1) break
                if (read > 0) emit(buffer.copyOf(read))
            }
        } finally {
            // disconnect() rather than close(): closing a keep-alive stream that
            // has not reached EOF makes HttpURLConnection drain the remainder so
            // the socket can be reused, which blocks on exactly the stream the
            // caller has just walked away from. Disconnecting releases it
            // outright.
            connection.disconnect()
        }
    }
}

private fun InputStream?.readFully(): String {
    if (this == null) {
        return ""
    }

    return this.bufferedReader(Charsets.UTF_8).use { reader ->
        reader.readText()
    }
}
