package app.independo.inderun.providers.neuralspeech

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/**
 * Reads the files of a speech model package (graphs aside: configs, voices, frontend assets) by
 * their package-relative names. Platform-neutral so a pipeline runs over a directory, an app
 * asset or memory alike.
 */
interface SpeechPackageFiles {
    suspend fun read(file: String): ByteArray
}

/**
 * Throws `model file name invalid: <file>` ([NeuralSpeechRuntimeErrorKind.Capability]) for a name a
 * package file may not have: empty, absolute, or with a `..` component, so a package cannot reach
 * outside its directory. Every package file reader and graph executor applies it.
 */
fun checkPackageFileName(file: String) {
    if (file.isEmpty() || file.startsWith("/") || file.startsWith("\\") || ".." in file.split('/', '\\')) {
        throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Capability, "model file name invalid: $file")
    }
}

/**
 * [SpeechPackageFiles] over a directory on disk. Names that are empty, absolute or contain a `..`
 * component are refused ([checkPackageFileName]), so a package cannot read outside its directory.
 */
class DirectoryPackageFiles(private val directory: File) : SpeechPackageFiles {
    override suspend fun read(file: String): ByteArray {
        checkPackageFileName(file)
        return withContext(Dispatchers.IO) {
            try {
                File(directory, file).readBytes()
            } catch (error: IOException) {
                throw NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Capability, "model files missing: $file", error)
            }
        }
    }
}
