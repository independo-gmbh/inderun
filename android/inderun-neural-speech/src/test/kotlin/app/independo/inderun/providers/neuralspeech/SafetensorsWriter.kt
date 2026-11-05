package app.independo.inderun.providers.neuralspeech

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Test-side safetensors writer: the production code only reads the format. */
internal fun encodeSafetensors(
    tensors: List<Pair<String, SpeechTensor>>,
    metadata: Map<String, String> = emptyMap(),
): ByteArray {
    val header = JSONObject()
    header.put("__metadata__", JSONObject(metadata))
    val body = mutableListOf<ByteArray>()
    var offset = 0
    for ((name, tensor) in tensors) {
        val bytes: ByteArray
        val dtype: String
        when (val data = tensor.data) {
            is SpeechTensorData.F32 -> {
                dtype = "F32"
                bytes = ByteBuffer.allocate(data.values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
                    .also { buffer -> data.values.forEach { buffer.putFloat(it) } }.array()
            }

            is SpeechTensorData.I64 -> {
                dtype = "I64"
                bytes = ByteBuffer.allocate(data.values.size * 8).order(ByteOrder.LITTLE_ENDIAN)
                    .also { buffer -> data.values.forEach { buffer.putLong(it) } }.array()
            }
        }
        header.put(
            name,
            JSONObject()
                .put("dtype", dtype)
                .put("shape", JSONArray(tensor.shape))
                .put("data_offsets", JSONArray(listOf(offset, offset + bytes.size))),
        )
        body += bytes
        offset += bytes.size
    }
    return assembleSafetensors(header.toString().toByteArray(Charsets.UTF_8), body)
}

/** Frames an arbitrary header and body: the 8-byte little-endian header length comes first. */
internal fun assembleSafetensors(header: ByteArray, body: List<ByteArray>): ByteArray {
    val length = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(header.size.toLong()).array()
    return body.fold(length + header) { acc, part -> acc + part }
}
