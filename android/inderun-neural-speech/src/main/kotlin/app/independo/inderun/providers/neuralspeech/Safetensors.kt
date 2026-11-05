package app.independo.inderun.providers.neuralspeech

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A parsed safetensors file: its tensors by name and the `__metadata__` string map. */
data class SafetensorsFile(val tensors: Map<String, SpeechTensor>, val metadata: Map<String, String>)

/**
 * Reader for the safetensors format: an 8-byte little-endian header length, the JSON header and
 * the byte buffer. Only `F32` and `I64` tensors are accepted; any other dtype is refused by name.
 */
object Safetensors {
    private fun malformed(why: String) = NeuralSpeechRuntimeError(NeuralSpeechRuntimeErrorKind.Capability, "voice file malformed: $why")

    /** A non-negative whole number that fits a `Long` exactly, or null. */
    private fun integer(value: Any?): Long? {
        val number = value as? Number ?: return null
        val double = number.toDouble()
        if (!(double >= 0.0 && double < 9_007_199_254_740_992.0 && double == Math.floor(double))) return null
        return double.toLong()
    }

    private fun integers(array: JSONArray?): List<Long>? {
        if (array == null) return null
        return (0 until array.length()).map { integer(array.opt(it)) ?: return null }
    }

    fun parse(bytes: ByteArray): SafetensorsFile {
        if (bytes.size < 8) throw malformed("shorter than the 8-byte header length")
        val headerLength = ByteBuffer.wrap(bytes, 0, 8).order(ByteOrder.LITTLE_ENDIAN).long
        if (headerLength < 0 || headerLength > bytes.size - 8L) throw malformed("header length exceeds the file")
        val bufferStart = 8 + headerLength.toInt()

        val header = try {
            JSONObject(String(bytes, 8, headerLength.toInt(), Charsets.UTF_8))
        } catch (error: JSONException) {
            throw malformed("header is not valid JSON")
        }

        val bufferLength = (bytes.size - bufferStart).toLong()
        val tensors = mutableMapOf<String, SpeechTensor>()
        val metadata = mutableMapOf<String, String>()
        for (name in header.keys()) {
            val raw = header.opt(name)
            if (name == "__metadata__") {
                val map = raw as? JSONObject ?: continue
                for (key in map.keys()) {
                    metadata[key] = map.opt(key) as? String ?: throw malformed("metadata '$key' is not a string")
                }
                continue
            }
            val entry = raw as? JSONObject ?: JSONObject()
            val dtype = entry.opt("dtype") as? String
            if (dtype != "F32" && dtype != "I64") {
                throw NeuralSpeechRuntimeError(
                    NeuralSpeechRuntimeErrorKind.Capability,
                    "voice file unsupported: dtype ${dtype ?: "unknown"} of '$name'",
                )
            }
            val shape = integers(entry.optJSONArray("shape"))
            val offsets = integers(entry.optJSONArray("data_offsets"))
            if (shape == null || offsets == null || offsets.size != 2) {
                throw malformed("'$name' has an invalid shape or data_offsets")
            }
            val (begin, end) = offsets
            if (begin > end || end > bufferLength) throw malformed("'$name' offsets lie outside the buffer")
            val width = if (dtype == "F32") 4L else 8L
            val count = try {
                shape.fold(1L) { product, dimension -> Math.multiplyExact(product, dimension) }
            } catch (error: ArithmeticException) {
                throw malformed("'$name' has an invalid shape or data_offsets")
            }
            if (count > Int.MAX_VALUE || end - begin != count * width) {
                throw malformed("'$name' byte range does not match its shape")
            }
            val window = ByteBuffer.wrap(bytes, bufferStart + begin.toInt(), (end - begin).toInt()).slice()
                .order(ByteOrder.LITTLE_ENDIAN)
            val data = if (dtype == "F32") {
                SpeechTensorData.F32(FloatArray(count.toInt()).also { window.asFloatBuffer().get(it) })
            } else {
                SpeechTensorData.I64(LongArray(count.toInt()).also { window.asLongBuffer().get(it) })
            }
            tensors[name] = SpeechTensor(shape.map { it.toInt() }, data)
        }
        return SafetensorsFile(tensors, metadata)
    }
}
