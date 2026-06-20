package com.independo.inderun.core

import com.independo.inderun.contracts.HttpRequest
import com.independo.inderun.contracts.HttpResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
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
                statusText = statusText
            )
        } finally {
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
