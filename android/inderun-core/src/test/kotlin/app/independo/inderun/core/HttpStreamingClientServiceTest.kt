package app.independo.inderun.core

import app.independo.inderun.contracts.HttpRequest
import app.independo.inderun.contracts.Method
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Exercises [URLConnectionStreamingHttpClientService] against a real loopback
 * socket rather than a mocked connection: the behavior under test is precisely
 * that bytes are surfaced before the response is complete, which a fake
 * connection cannot demonstrate.
 */
class HttpStreamingClientServiceTest {
    private var server: ServerSocket? = null

    @After
    fun tearDown() {
        server?.close()
    }

    private fun serve(handler: (Socket, OutputStream) -> Unit): String {
        val socket = ServerSocket(0)
        server = socket
        thread(isDaemon = true) {
            try {
                while (!socket.isClosed) {
                    val client = socket.accept()
                    thread(isDaemon = true) {
                        try {
                            drainRequest(client)
                            client.getOutputStream().use { output -> handler(client, output) }
                        } catch (_: Exception) {
                            // The client hanging up mid-response is an expected
                            // outcome in the cancellation test.
                        } finally {
                            client.close()
                        }
                    }
                }
            } catch (_: Exception) {
                // Socket closed during teardown.
            }
        }
        return "http://127.0.0.1:${socket.localPort}/stream"
    }

    private fun drainRequest(client: Socket) {
        val reader = client.getInputStream().bufferedReader(Charsets.UTF_8)
        while (true) {
            val line = reader.readLine() ?: break
            if (line.isEmpty()) break
        }
    }

    private fun OutputStream.writeChunk(text: String) {
        write(text.toByteArray(Charsets.UTF_8))
        flush()
    }

    private fun OutputStream.writeHead(status: String, contentType: String, extra: String = "") {
        writeChunk(
            "HTTP/1.1 $status\r\n" +
                "Content-Type: $contentType\r\n" +
                extra +
                "Transfer-Encoding: chunked\r\n" +
                "\r\n",
        )
    }

    private fun OutputStream.writeHttpChunk(text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        writeChunk(Integer.toHexString(bytes.size) + "\r\n" + text + "\r\n")
    }

    private fun OutputStream.writeLastChunk() = writeChunk("0\r\n\r\n")

    @Test
    fun `resolves the response head with lower-cased headers before the body`() = runBlocking {
        val url = serve { _, output ->
            output.writeHead("200 OK", "text/event-stream")
            output.writeHttpChunk("data: a\n\n")
            output.writeLastChunk()
        }

        val response = URLConnectionStreamingHttpClientService()
            .stream(HttpRequest(body = null, headers = null, method = Method.Get, timeoutMs = 5_000, url = url))

        assertEquals(200L, response.status)
        assertEquals("text/event-stream", response.headers["content-type"])
        assertEquals("data: a\n\n", response.body.toList().joinToString("") { String(it, Charsets.UTF_8) })
    }

    @Test
    fun `surfaces body bytes before the response is complete`() = runBlocking {
        val firstChunkSeen = CountDownLatch(1)
        val url = serve { _, output ->
            output.writeHead("200 OK", "text/event-stream")
            output.writeHttpChunk("first")
            // The rest is withheld until the collector has already observed the
            // first chunk, so passing this test is impossible if the client
            // buffers the whole body.
            firstChunkSeen.await(5, TimeUnit.SECONDS)
            output.writeHttpChunk("second")
            output.writeLastChunk()
        }

        val response = URLConnectionStreamingHttpClientService()
            .stream(HttpRequest(body = null, headers = null, method = Method.Get, timeoutMs = 5_000, url = url))

        val received = mutableListOf<String>()
        withTimeout(10_000) {
            response.body.collect { chunk ->
                received += String(chunk, Charsets.UTF_8)
                firstChunkSeen.countDown()
            }
        }

        assertEquals("first", received.first())
        assertEquals("firstsecond", received.joinToString(""))
    }

    @Test
    fun `stops reading and releases the connection when collection is cancelled`() = runBlocking {
        val serverSawDisconnect = CompletableDeferred<Boolean>()
        val url = serve { _, output ->
            output.writeHead("200 OK", "text/event-stream")
            output.writeHttpChunk("first")
            try {
                // Keep pushing until the client goes away; a broken pipe is the
                // signal that cancellation actually tore the connection down.
                repeat(10_000) {
                    output.writeHttpChunk("more")
                    Thread.sleep(1)
                }
                serverSawDisconnect.complete(false)
            } catch (_: Exception) {
                serverSawDisconnect.complete(true)
            }
        }

        val response = URLConnectionStreamingHttpClientService()
            .stream(HttpRequest(body = null, headers = null, method = Method.Get, timeoutMs = 5_000, url = url))

        val received = mutableListOf<String>()
        withTimeout(10_000) {
            try {
                response.body.collect { chunk ->
                    received += String(chunk, Charsets.UTF_8)
                    throw CollectionStopped()
                }
            } catch (_: CollectionStopped) {
                // Expected: aborts collection after the first chunk.
            }
        }

        assertTrue(received.isNotEmpty())
        assertTrue(withTimeout(10_000) { serverSawDisconnect.await() })
    }

    @Test
    fun `cancelling the collector ends a read that is blocked waiting for data`() = runBlocking {
        // The normal state of an idle SSE stream: one chunk delivered, and the
        // socket then silent. A cooperative cancellation check cannot end a read
        // that is already blocked, so a hang here is the regression.
        val url = serve { _, output ->
            output.writeHead("200 OK", "text/event-stream")
            output.writeHttpChunk("first")
            Thread.sleep(60_000)
        }

        val response = URLConnectionStreamingHttpClientService()
            .stream(HttpRequest(body = null, headers = null, method = Method.Get, timeoutMs = 500, url = url))

        val firstChunk = CompletableDeferred<String>()
        val collector = launch(Dispatchers.IO) {
            response.body.collect { chunk -> firstChunk.complete(String(chunk, Charsets.UTF_8)) }
        }

        assertEquals("first", withTimeout(10_000) { firstChunk.await() })
        collector.cancel()
        withTimeout(10_000) { collector.join() }
        assertTrue(collector.isCompleted)
    }

    @Test
    fun `does not impose an idle deadline on an established stream`() = runBlocking {
        // timeoutMs bounds the response head only. A gap longer than it must not
        // abort a stream that is already established.
        val url = serve { _, output ->
            output.writeHead("200 OK", "text/event-stream")
            output.writeHttpChunk("first")
            Thread.sleep(600)
            output.writeHttpChunk("second")
            output.writeLastChunk()
        }

        val response = URLConnectionStreamingHttpClientService()
            .stream(HttpRequest(body = null, headers = null, method = Method.Get, timeoutMs = 200, url = url))

        val received = withTimeout(10_000) {
            response.body.toList().joinToString("") { String(it, Charsets.UTF_8) }
        }

        assertEquals("firstsecond", received)
    }

    @Test
    fun `exposes a non-2xx head and its error body`() = runBlocking {
        val url = serve { _, output ->
            output.writeHead("429 Too Many Requests", "application/json", extra = "Retry-After: 3\r\n")
            output.writeHttpChunk("""{"error":{"message":"slow down"}}""")
            output.writeLastChunk()
        }

        val response = URLConnectionStreamingHttpClientService()
            .stream(HttpRequest(body = null, headers = null, method = Method.Get, timeoutMs = 5_000, url = url))

        assertEquals(429L, response.status)
        assertEquals("3", response.headers["retry-after"])
        assertEquals(
            """{"error":{"message":"slow down"}}""",
            response.body.toList().joinToString("") { String(it, Charsets.UTF_8) },
        )
    }

    private class CollectionStopped : RuntimeException()
}
