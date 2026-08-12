package app.independo.inderun.demo

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * A downloadable ONNX text-generation model for the ONNX Local provider.
 *
 * [app.independo.inderun.providers.onnx.SystemAndroidOnnxGenAiRuntime] (the SDK's default Android
 * ONNX runtime) only supports plain decoder-only graphs (`input_ids`/`attention_mask` in, `logits`
 * out, no `past_key_values`), so the catalog is limited to small base language models like this one
 * until https://github.com/independo-gmbh/inderun/issues/126 adds KV-cache support. Add more
 * capable instruction-tuned models here once that lands.
 */
internal data class DemoOnnxModelOption(
    val id: String,
    val title: String,
    val huggingFaceRepo: String,
    val files: List<RemoteFile>,
) {
    data class RemoteFile(
        /** Path within the Hugging Face repo. */
        val repoPath: String,
        /** Filename this is saved as locally; must match what the ONNX runtime expects. */
        val localFileName: String,
        /** Approximate share of total download size, used to weight combined progress. */
        val weight: Double,
    )

    companion object {
        val distilgpt2Quantized = DemoOnnxModelOption(
            id = "distilgpt2-quantized",
            title = "DistilGPT-2 (quantized, ~84 MB)",
            huggingFaceRepo = "Xenova/distilgpt2",
            files = listOf(
                RemoteFile(repoPath = "onnx/decoder_model_quantized.onnx", localFileName = "model.onnx", weight = 0.97),
                RemoteFile(repoPath = "tokenizer.json", localFileName = "tokenizer.json", weight = 0.025),
                RemoteFile(repoPath = "tokenizer_config.json", localFileName = "tokenizer_config.json", weight = 0.004),
                RemoteFile(repoPath = "config.json", localFileName = "config.json", weight = 0.001),
            ),
        )

        val catalog: List<DemoOnnxModelOption> = listOf(distilgpt2Quantized)
    }
}

/** User-facing selection for the ONNX Local provider, including the no-download fixture option. */
internal enum class DemoOnnxModelSelection(val title: String, val modelOption: DemoOnnxModelOption?) {
    Fixture(title = "Fixture (no download)", modelOption = null),
    Distilgpt2Quantized(title = DemoOnnxModelOption.distilgpt2Quantized.title, modelOption = DemoOnnxModelOption.distilgpt2Quantized),
}

internal sealed interface DemoOnnxDownloadState {
    data object Idle : DemoOnnxDownloadState
    data class Downloading(val progress: Float) : DemoOnnxDownloadState
    data object Ready : DemoOnnxDownloadState
    data class Failed(val message: String) : DemoOnnxDownloadState
}

internal class DemoOnnxDownloadException(message: String) : Exception(message)

/**
 * Resolves, checks, and downloads [DemoOnnxModelOption] files. An interface so tests can supply a
 * fake without depending on an Android [Context].
 */
internal interface DemoOnnxDownloader {
    /** Directory-relative-to-`filesDir` reference used as `Source.ref` for the `AppManaged` source. */
    fun relativeRef(model: DemoOnnxModelOption): String
    fun isDownloaded(model: DemoOnnxModelOption): Boolean
    suspend fun download(model: DemoOnnxModelOption, onProgress: (Float) -> Unit)
}

/**
 * Downloads a [DemoOnnxModelOption]'s files from Hugging Face into the app's private storage
 * (`context.filesDir`) so the ONNX Local provider can run real on-device generation without any
 * manual setup, mirroring the web demo's automatic model download via `@huggingface/transformers`
 * and the iOS demo's `DemoOnnxModelDownloader`-equivalent behavior.
 *
 * Downloaded files land under `inderun-demo-onnx-models/<model.id>/`, relative to `filesDir`, which
 * matches the `AppManaged` model source resolution
 * [app.independo.inderun.providers.onnx.SystemAndroidOnnxGenAiRuntime] performs (`filesDir` +
 * `source.ref`).
 */
internal class AndroidDemoOnnxModelDownloader(private val context: Context) : DemoOnnxDownloader {
    override fun relativeRef(model: DemoOnnxModelOption): String = "inderun-demo-onnx-models/${model.id}"

    fun localDirectory(model: DemoOnnxModelOption): File = File(context.filesDir, relativeRef(model))

    override fun isDownloaded(model: DemoOnnxModelOption): Boolean {
        val directory = localDirectory(model)
        return model.files.all { File(directory, it.localFileName).exists() }
    }

    override suspend fun download(model: DemoOnnxModelOption, onProgress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        val directory = localDirectory(model)
        directory.mkdirs()

        var completedWeight = 0.0
        val totalWeight = model.files.sumOf { it.weight }

        for (file in model.files) {
            val destination = File(directory, file.localFileName)
            if (!destination.exists()) {
                downloadFile(model, file, destination) { fileProgress ->
                    val overall = (completedWeight + fileProgress * file.weight) / totalWeight
                    onProgress(overall.toFloat())
                }
            }
            completedWeight += file.weight
            onProgress((completedWeight / totalWeight).toFloat())
        }
    }

    private fun downloadFile(
        model: DemoOnnxModelOption,
        file: DemoOnnxModelOption.RemoteFile,
        destination: File,
        onProgress: (Double) -> Unit,
    ) {
        val url = URL("https://huggingface.co/${model.huggingFaceRepo}/resolve/main/${file.repoPath}")
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = true
            connection.connect()

            val status = connection.responseCode
            if (status !in 200..299) {
                throw DemoOnnxDownloadException("Download failed with HTTP $status for $url")
            }

            val contentLength = connection.contentLengthLong
            val tempFile = File(destination.parentFile, "${destination.name}.tmp-${UUID.randomUUID()}")
            var bytesRead = 0L

            connection.inputStream.use { input ->
                tempFile.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var read = input.read(buffer)
                    while (read >= 0) {
                        output.write(buffer, 0, read)
                        bytesRead += read
                        if (contentLength > 0) {
                            onProgress(bytesRead.toDouble() / contentLength.toDouble())
                        }
                        read = input.read(buffer)
                    }
                }
            }

            destination.delete()
            if (!tempFile.renameTo(destination)) {
                tempFile.delete()
                throw DemoOnnxDownloadException("Failed to install downloaded file for ${file.repoPath}")
            }
        } finally {
            connection.disconnect()
        }
    }
}
