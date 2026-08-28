package app.independo.inderun.core

import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.HttpResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.job
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.net.HttpURLConnection
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
                // Bounds the wait for the response head only: readTimeout
                // applies per read, and an established stream keeps resetting
                // it rather than accumulating toward a total budget.
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
            throw throwable
        }

        val (status, statusText, headers) = head
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream

        HttpStreamResponse(
            status = status,
            statusText = statusText,
            headers = headers,
            body = stream.chunks().onCompletion { connection.disconnect() }.flowOn(Dispatchers.IO),
        )
    }

    private companion object {
        const val CHUNK_BYTES = 8 * 1024
    }

    private fun InputStream?.chunks(): Flow<ByteArray> = flow {
        val source = this@chunks ?: return@flow
        source.use { input ->
            val buffer = ByteArray(CHUNK_BYTES)
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = input.read(buffer)
                if (read == -1) break
                if (read > 0) emit(buffer.copyOf(read))
            }
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
