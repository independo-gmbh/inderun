package app.independo.inderun.core

import java.io.ByteArrayOutputStream

/**
 * A single dispatched server-sent event.
 *
 * [event] and [id] are `null` when the stream did not carry those fields.
 * [data] is the accumulated data payload with its trailing newline removed, and
 * is passed through verbatim — sentinels such as OpenAI's `[DONE]` are the
 * caller's concern, not the framing layer's.
 */
data class SseEvent(
    val event: String? = null,
    val data: String,
    val id: String? = null,
)

/**
 * Incremental server-sent events framer.
 *
 * Follows the WHATWG server-sent events stream parsing rules, minus
 * reconnection: `retry` is parsed as a field and ignored, and there is no
 * Last-Event-ID reconnect logic. Concretely that means:
 *
 * - lines end with LF, CRLF, or bare CR;
 * - a line beginning with `:` is a comment (servers send these as keep-alives);
 * - `field: value` strips exactly one leading space from the value, and a line
 *   with no colon is that field with an empty value;
 * - `data` fields accumulate, joined by newlines;
 * - a blank line dispatches the accumulated event, or resets without
 *   dispatching if no data was accumulated;
 * - a stream that ends mid-event does **not** dispatch the partial event, since
 *   a truncated event must never be reported as a complete one.
 *
 * Chunk boundaries are meaningless: bytes are buffered and decoded only at line
 * boundaries, so a chunk may split a multi-byte UTF-8 sequence or a line.
 *
 * Held to `contracts/fixtures/streaming/sse-framing.json` together with the
 * TypeScript and Swift implementations of the same protocol.
 *
 * Not thread-safe; one instance drives one stream.
 */
class SseParser {
    private val buffer = ByteArrayOutputStream()
    private var eventType: String? = null
    private var data: String? = null
    private var id: String? = null

    /** Feeds one raw body chunk and returns whatever events it completed. */
    fun consume(chunk: ByteArray): List<SseEvent> {
        buffer.write(chunk)
        return drain(atEnd = false)
    }

    /** Signals end of stream. Any pending, unterminated event is discarded. */
    fun finish(): List<SseEvent> = drain(atEnd = true)

    private fun drain(atEnd: Boolean): List<SseEvent> {
        val dispatched = mutableListOf<SseEvent>()
        while (true) {
            val line = takeLine(atEnd) ?: break
            handle(line)?.let { dispatched += it }
        }
        return dispatched
    }

    private fun takeLine(atEnd: Boolean): String? {
        val bytes = buffer.toByteArray()
        var index = 0
        while (index < bytes.size) {
            when (bytes[index]) {
                LINE_FEED -> return consumeLine(bytes, lineEnd = index, resumeAt = index + 1)
                CARRIAGE_RETURN -> {
                    val next = index + 1
                    // Withhold a trailing CR until we know whether an LF follows,
                    // unless the stream is over and no LF can arrive.
                    if (next == bytes.size && !atEnd) return null
                    val resumeAt = if (next < bytes.size && bytes[next] == LINE_FEED) next + 1 else next
                    return consumeLine(bytes, lineEnd = index, resumeAt = resumeAt)
                }
            }
            index++
        }
        return null
    }

    private fun consumeLine(bytes: ByteArray, lineEnd: Int, resumeAt: Int): String {
        val line = String(bytes, 0, lineEnd, Charsets.UTF_8)
        buffer.reset()
        buffer.write(bytes, resumeAt, bytes.size - resumeAt)
        return line
    }

    private fun handle(line: String): SseEvent? {
        if (line.isEmpty()) return takeEvent()
        if (line.startsWith(":")) return null

        val colon = line.indexOf(':')
        val field = if (colon == -1) line else line.substring(0, colon)
        var value = if (colon == -1) "" else line.substring(colon + 1)
        if (value.startsWith(" ")) value = value.substring(1)

        when (field) {
            "event" -> eventType = value
            "data" -> data = data?.let { "$it\n$value" } ?: value
            // Per the SSE spec an id containing a NUL is ignored outright.
            "id" -> if (!value.contains(NUL)) id = value
            // `retry` and anything unrecognized are dropped rather than erroring.
            else -> Unit
        }

        return null
    }

    private fun takeEvent(): SseEvent? {
        val pending = data
        val event = if (pending == null) null else SseEvent(event = eventType, data = pending, id = id)
        eventType = null
        data = null
        id = null
        return event
    }

    private companion object {
        const val LINE_FEED: Byte = 0x0A
        const val CARRIAGE_RETURN: Byte = 0x0D
        const val NUL: Char = '\u0000'
    }
}
