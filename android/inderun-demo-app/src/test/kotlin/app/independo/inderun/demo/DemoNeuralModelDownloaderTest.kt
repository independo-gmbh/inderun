package app.independo.inderun.demo

import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest

class DemoNeuralModelDownloaderTest {
    @get:Rule
    val temp = TemporaryFolder()

    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private val contents = mapOf(
        "config.json" to "config".toByteArray(),
        "text.onnx" to ByteArray(200_000) { (it % 251).toByte() },
        "voices/a.safetensors" to "voice-a".toByteArray(),
    )

    private fun file(path: String, host: String = "https://huggingface.co/x") = CatalogFile(
        role = null,
        path = path,
        url = "$host/$path",
        sha256 = sha(contents.getValue(path)),
        bytes = contents.getValue(path).size.toLong(),
    )

    private val license = CatalogLicense("Apache-2.0", null, "none", "attribution line")
    private val entry = CatalogEntry(
        id = "test-model",
        variant = "onnx-int8",
        version = "1",
        license = license,
        reviewStatus = "benchmark_only",
        reviewNotes = null,
        runtimeFormat = "onnx",
        minOsVersion = null,
        speechPipeline = "articulino",
        sampleRate = 24000,
        channels = 1,
        graphs = emptyMap(),
        frontendKind = "grapheme",
        frontendAssets = emptyMap(),
        files = listOf(file("config.json"), file("text.onnx", "https://github.com/independo-gmbh/inderun/releases/download/t")),
        voices = listOf(
            CatalogVoice(
                "a",
                "A",
                listOf("de-DE"),
                "female",
                file("voices/a.safetensors"),
                CatalogLicense("LicenseRef-Demo", null, "demo use", null),
            ),
        ),
    )

    /** Serves `contents` by url suffix, or what `serve` overrides; counts requests. */
    private class FakeTransport(val serve: (String) -> TransportResponse) : NeuralTransport {
        val requests = mutableListOf<String>()
        override fun open(url: String): TransportResponse {
            requests += url
            return serve(url)
        }
    }

    private fun ok(url: String) = TransportResponse(200, ByteArrayInputStream(contents.getValue(entry.allFiles.first { it.url == url }.path)))

    private val root get() = temp.root

    @Test
    fun declined_consent_makes_no_request() = runTest {
        val transport = FakeTransport(::ok)
        val result = DemoNeuralModelDownloader(root, transport).download(entry, consent = { false })

        assertEquals(NeuralDownloadResult.Declined, result)
        assertTrue(transport.requests.isEmpty())
        assertEquals(0, root.list()!!.size)
    }

    @Test
    fun consent_lists_size_and_every_licence_before_anything_is_fetched() = runTest {
        val seen = mutableListOf<ConsentPrompt>()
        DemoNeuralModelDownloader(root, FakeTransport(::ok)).download(entry, consent = {
            seen += it
            false
        })

        val prompt = seen.single()
        assertEquals(entry.allFiles.sumOf { it.bytes }, prompt.totalBytes)
        assertEquals(listOf("Apache-2.0", "attribution line", "LicenseRef-Demo: demo use"), prompt.licenses)
    }

    @Test
    fun installs_all_files_and_reports_them_installed() = runTest {
        val downloader = DemoNeuralModelDownloader(root, FakeTransport(::ok))
        assertFalse(downloader.isInstalled(entry))

        assertEquals(NeuralDownloadResult.Installed, downloader.download(entry, consent = { true }))

        assertTrue(downloader.isInstalled(entry))
        assertArrayEquals(contents.getValue("voices/a.safetensors"), File(downloader.directory(entry), "voices/a.safetensors").readBytes())
        assertEquals(emptyList<String>(), downloader.directory(entry).walkTopDown().filter { it.name.endsWith(".part") }.map { it.name }.toList())
    }

    @Test
    fun the_installation_check_creates_nothing() = runTest {
        assertFalse(DemoNeuralModelDownloader(root, FakeTransport(::ok)).isInstalled(entry))
        assertEquals(0, root.list()!!.size)
    }

    @Test
    fun resume_skips_verified_files() = runTest {
        // First attempt: the big file fails mid-way, the small one is already in place.
        val failing = FakeTransport { url ->
            if (url.endsWith("text.onnx")) TransportResponse(503, null) else ok(url)
        }
        val downloader = DemoNeuralModelDownloader(root, failing)
        try {
            downloader.download(entry, consent = { true })
            fail()
        } catch (error: NeuralDownloadException) {
            assertEquals("download failed (HTTP 503): text.onnx", error.message)
        }
        assertTrue(File(downloader.directory(entry), "config.json").isFile)

        val resumed = FakeTransport(::ok)
        DemoNeuralModelDownloader(root, resumed).download(entry, consent = { true })

        assertEquals(listOf(entry.files[1].url, entry.voices[0].file.url), resumed.requests)
    }

    @Test
    fun partial_file_is_not_accepted() = runTest {
        val target = File(DemoNeuralModelDownloader(root, FakeTransport(::ok)).directory(entry), "text.onnx")
        target.parentFile!!.mkdirs()
        target.writeBytes(contents.getValue("text.onnx").copyOf(1000)) // truncated

        val transport = FakeTransport(::ok)
        val downloader = DemoNeuralModelDownloader(root, transport)
        assertFalse(downloader.isInstalled(entry))
        downloader.download(entry, consent = { true })

        assertTrue(transport.requests.contains(entry.files[1].url))
        assertArrayEquals(contents.getValue("text.onnx"), target.readBytes())
    }

    @Test
    fun a_truncated_response_is_a_checksum_mismatch_and_leaves_nothing() = runTest {
        val short = FakeTransport { url ->
            if (url.endsWith("text.onnx")) TransportResponse(200, ByteArrayInputStream(ByteArray(10))) else ok(url)
        }
        val downloader = DemoNeuralModelDownloader(root, short)
        try {
            downloader.download(entry, consent = { true })
            fail()
        } catch (error: NeuralDownloadException) {
            assertEquals("checksum mismatch: text.onnx", error.message)
        }
        val dir = downloader.directory(entry)
        assertFalse(File(dir, "text.onnx").exists())
        assertFalse(File(dir, "text.onnx.part").exists())
    }

    @Test
    fun checksum_mismatch_removes_the_file() = runTest {
        val wrong = FakeTransport { url ->
            if (url.endsWith("config.json")) {
                TransportResponse(200, ByteArrayInputStream("tampered".toByteArray().copyOf(contents.getValue("config.json").size)))
            } else {
                ok(url)
            }
        }
        val downloader = DemoNeuralModelDownloader(root, wrong)
        try {
            downloader.download(entry, consent = { true })
            fail()
        } catch (error: NeuralDownloadException) {
            assertEquals("checksum mismatch: config.json", error.message)
        }
        assertFalse(File(downloader.directory(entry), "config.json").exists())
    }

    @Test
    fun storage_error_is_reported_and_the_partial_removed() = runTest {
        val full = { target: File ->
            object : OutputStream() {
                private val real = target.outputStream()
                private var written = 0
                override fun write(b: Int) = real.write(b)
                override fun write(b: ByteArray, off: Int, len: Int) {
                    if (written > 0) throw IOException("write failed: ENOSPC (No space left on device)")
                    real.write(b, off, len)
                    written += len
                }
                override fun close() = real.close()
            }
        }
        val downloader = DemoNeuralModelDownloader(root, FakeTransport(::ok), full)
        try {
            downloader.download(entry, consent = { true })
            fail()
        } catch (error: NeuralDownloadException) {
            assertEquals("not enough storage space to save text.onnx; free some space and try again", error.message)
        }
        val dir = downloader.directory(entry)
        assertFalse(File(dir, "text.onnx").exists())
        assertFalse(File(dir, "text.onnx.part").exists())
    }

    @Test
    fun an_unpublished_release_asset_says_so() = runTest {
        val notFound = FakeTransport { url -> if (url.startsWith("https://github.com/")) TransportResponse(404, null) else ok(url) }
        try {
            DemoNeuralModelDownloader(root, notFound).download(entry, consent = { true })
            fail()
        } catch (error: NeuralDownloadException) {
            assertEquals("asset not published yet (HTTP 404): text.onnx", error.message)
        }
    }

    @Test
    fun an_unreadable_file_while_verifying_is_refetched_not_a_crash() = runTest {
        val downloader = DemoNeuralModelDownloader(root, FakeTransport(::ok))
        val target = File(downloader.directory(entry), "config.json")
        target.parentFile!!.mkdirs()
        target.writeBytes(ByteArray(contents.getValue("config.json").size)) // right size, wrong bytes
        target.setReadable(false)

        val transport = FakeTransport(::ok)
        assertFalse(DemoNeuralModelDownloader(root, transport).isInstalled(entry))
        val result = DemoNeuralModelDownloader(root, transport).download(entry, consent = { true })

        assertEquals(NeuralDownloadResult.Installed, result)
        assertTrue(transport.requests.contains(entry.files[0].url))
        assertArrayEquals(contents.getValue("config.json"), target.readBytes())
    }

    @Test
    fun cancelling_while_the_connection_is_being_established_returns_promptly() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val aborted = java.util.concurrent.CountDownLatch(1)
        val requests = java.util.Collections.synchronizedList(mutableListOf<String>())
        val transport = object : NeuralTransport {
            override fun open(url: String): TransportResponse = open(url, TransportCancellation())
            override fun open(url: String, cancellation: TransportCancellation): TransportResponse {
                requests += url
                cancellation.onCancel { aborted.countDown() }
                entered.countDown()
                // A stalled DNS, TLS or server-response step: only an abort ends it, as disconnect() does.
                if (!aborted.await(10, java.util.concurrent.TimeUnit.SECONDS)) throw IOException("connect timed out")
                throw IOException("Socket closed")
            }
        }
        val downloader = DemoNeuralModelDownloader(root, transport)
        var thrown: Throwable? = null
        kotlinx.coroutines.runBlocking {
            val job = launch(kotlinx.coroutines.Dispatchers.Default) {
                try {
                    downloader.download(entry, consent = { true })
                } catch (error: Throwable) {
                    thrown = error
                    throw error
                }
            }
            assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            val started = System.nanoTime()
            kotlinx.coroutines.withTimeout(5_000) { job.cancelAndJoin() }
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertTrue("cancel took $elapsedMs ms", elapsedMs < 2_000)
        }

        // The abort surfaced as a cancel, not as a download failure.
        assertTrue(thrown is kotlinx.coroutines.CancellationException)
        assertEquals(listOf(entry.files[0].url), requests.toList())
        val dir = downloader.directory(entry)
        assertFalse(File(dir, "config.json").exists())
        assertFalse(File(dir, "config.json.part").exists())
    }

    @Test
    fun cancelling_mid_stream_leaves_no_file_and_makes_no_further_request() {
        val reached = java.util.concurrent.CountDownLatch(1)
        val closed = java.util.concurrent.CountDownLatch(1)
        val stream = object : java.io.InputStream() {
            private var delivered = false
            override fun read(): Int = error("unused")
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (!delivered) {
                    delivered = true
                    b[off] = 1
                    return 1
                }
                reached.countDown()
                closed.await()
                throw IOException("stream closed")
            }
        }
        val transport = FakeTransport { url ->
            if (url.endsWith("text.onnx")) TransportResponse(200, stream) { closed.countDown() } else ok(url)
        }
        val downloader = DemoNeuralModelDownloader(root, transport)
        kotlinx.coroutines.runBlocking {
            val job = launch(kotlinx.coroutines.Dispatchers.Default) { downloader.download(entry, consent = { true }) }
            assertTrue(reached.await(5, java.util.concurrent.TimeUnit.SECONDS))
            kotlinx.coroutines.withTimeout(5_000) { job.cancelAndJoin() }
        }

        val dir = downloader.directory(entry)
        assertFalse(File(dir, "text.onnx").exists())
        assertFalse(File(dir, "text.onnx.part").exists())
        assertEquals(listOf(entry.files[0].url, entry.files[1].url), transport.requests)
    }
}
