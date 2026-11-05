package app.independo.inderun.providers.onnx

import android.content.Context
import app.independo.inderun.contracts.ModelPackage
import app.independo.inderun.contracts.SourceType
import java.io.File

/**
 * Resolves a model package's `source` to a directory of files on disk, extracting a bundled
 * asset directory into app-private storage on first use, and checks the files against the
 * package's declared checksums. Shared by the text generation sessions and the neural speech
 * runtime so both resolve a source the same way.
 */
internal class OnnxModelDirectory(private val context: Context) {
    fun checkFilesExist(directory: File, requiredFiles: List<String>) {
        requiredFiles.forEach { relativePath ->
            val file = File(directory, relativePath)
            if (!file.exists()) {
                throw OnnxRuntimeError(
                    kind = OnnxRuntimeErrorKind.CAPABILITY,
                    message = "model files missing: '$relativePath' not found at ${file.absolutePath}.",
                )
            }
        }
    }

    fun resolve(modelPackage: ModelPackage, sourceType: SourceType, cacheKey: String): File {
        val ref = modelPackage.source?.ref
        return when (sourceType) {
            SourceType.Bundled -> {
                val relative = ref.orEmpty()
                val assetDir = File(
                    context.filesDir,
                    "inderun-onnx-assets/${modelPackage.id}/${cacheKeyDigest(cacheKey)}",
                )
                extractAssetDirectory(relative, assetDir)
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
                message = "model source unavailable: '${sourceType.rawValue}' model sources are " +
                    "deferred on Android.",
            )
        }
    }

    /**
     * Extracts a bundled asset directory into app-private storage exactly once per
     * [cacheKeyDigest], atomically: the copy lands in a sibling temp directory, a completion
     * marker is written last, and only then is the temp directory moved into place. A directory
     * missing the marker (never completed, or a previous run crashed mid-copy) is re-extracted
     * rather than trusted.
     */
    private fun extractAssetDirectory(assetPath: String, targetDir: File) {
        if (File(targetDir, EXTRACTION_COMPLETE_MARKER).exists()) return

        val tempDir = File(targetDir.parentFile, "${targetDir.name}.tmp-${System.nanoTime()}")
        tempDir.deleteRecursively()
        tempDir.mkdirs()
        try {
            copyAssetTree(assetPath, tempDir)
            val completionMarker = File(tempDir, EXTRACTION_COMPLETE_MARKER)
            if (!completionMarker.createNewFile()) {
                throw IllegalStateException(
                    "failed to create extraction completion marker '$EXTRACTION_COMPLETE_MARKER'.",
                )
            }
        } catch (error: Throwable) {
            tempDir.deleteRecursively()
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model source unavailable: failed to extract bundled model assets for '$assetPath'.",
                originalError = error,
            )
        }

        targetDir.deleteRecursively()
        if (!tempDir.renameTo(targetDir)) {
            tempDir.deleteRecursively()
            throw OnnxRuntimeError(
                kind = OnnxRuntimeErrorKind.CAPABILITY,
                message = "model source unavailable: failed to install extracted model assets for '$assetPath'.",
            )
        }
    }

    private fun copyAssetTree(assetPath: String, targetDir: File) {
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
                val childDir = File(targetDir, entry)
                childDir.mkdirs()
                copyAssetTree(childAssetPath, childDir)
            }
        }
    }

    /**
     * Verifies every file named in `integrity.checksums`, not only the required-file list, so a
     * checksum declared for the tokenizer or config file is enforced too. Files the map names but
     * that this runtime did not resolve a path for are skipped; an unsupported checksum algorithm
     * is a capability failure rather than a silently skipped check.
     */
    fun verifyChecksums(directory: File, modelPackage: ModelPackage) {
        val checksums = modelPackage.integrity?.checksums ?: return
        for ((relativePath, expected) in checksums) {
            val file = File(directory, relativePath)
            if (!file.exists()) continue
            verifyChecksum(file, relativePath, expected)
        }
    }

    private companion object {
        const val EXTRACTION_COMPLETE_MARKER = ".inderun-onnx-extraction-complete"
    }
}
