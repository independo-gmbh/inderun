import Foundation

/// A single dispatched server-sent event.
///
/// `event` and `id` are `nil` when the stream did not carry those fields.
/// `data` is the accumulated data payload with its trailing newline removed, and
/// is passed through verbatim — sentinels such as OpenAI's `[DONE]` are the
/// caller's concern, not the framing layer's.
public struct SseEvent: Equatable, Sendable {
    public let event: String?
    public let data: String
    public let id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental server-sent events framer.
///
/// Follows the WHATWG server-sent events stream parsing rules, minus
/// reconnection: `retry` is parsed as a field and ignored, and there is no
/// Last-Event-ID reconnect logic. Concretely that means:
///
/// - lines end with LF, CRLF, or bare CR;
/// - a line beginning with `:` is a comment (servers send these as keep-alives);
/// - `field: value` strips exactly one leading space from the value, and a line
///   with no colon is that field with an empty value;
/// - `data` fields accumulate, joined by newlines;
/// - a blank line dispatches the accumulated event, or resets without
///   dispatching if no data was accumulated;
/// - a stream that ends mid-event does **not** dispatch the partial event, since
///   a truncated event must never be reported as a complete one.
///
/// Chunk boundaries are meaningless: bytes are buffered and decoded only at line
/// boundaries, so a chunk may split a multi-byte UTF-8 sequence or a line.
///
/// Held to `contracts/fixtures/streaming/sse-framing.json` together with the
/// TypeScript and Kotlin implementations of the same protocol.
public struct SseParser {
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private var buffer = Data()
    private var eventType: String?
    private var data: String?
    private var id: String?

    public init() {}

    /// Feeds one raw body chunk and returns whatever events it completed.
    public mutating func consume(_ chunk: Data) -> [SseEvent] {
        buffer.append(chunk)
        return drain(atEnd: false)
    }

    /// Signals end of stream. Any pending, unterminated event is discarded.
    public mutating func finish() -> [SseEvent] {
        drain(atEnd: true)
    }

    private mutating func drain(atEnd: Bool) -> [SseEvent] {
        var dispatched: [SseEvent] = []
        while let line = takeLine(atEnd: atEnd) {
            if let event = handle(line: line) {
                dispatched.append(event)
            }
        }
        return dispatched
    }

    private mutating func takeLine(atEnd: Bool) -> String? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let byte = buffer[index]
            if byte == Self.lineFeed {
                let line = Self.decodeLine(buffer[buffer.startIndex ..< index])
                buffer = Data(buffer[buffer.index(after: index)...])
                return line
            }
            if byte == Self.carriageReturn {
                let next = buffer.index(after: index)
                // Withhold a trailing CR until we know whether an LF follows,
                // unless the stream is over and no LF can arrive.
                if next == buffer.endIndex, !atEnd {
                    return nil
                }
                let line = Self.decodeLine(buffer[buffer.startIndex ..< index])
                let skipTo = (next < buffer.endIndex && buffer[next] == Self.lineFeed)
                    ? buffer.index(after: next)
                    : next
                buffer = Data(buffer[skipTo...])
                return line
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    // The SSE specification mandates decoding the byte stream as UTF-8 with
    // invalid sequences replaced, never failing — a malformed byte must not
    // abort an otherwise healthy stream — so the non-failable initializer is
    // the correct one here.
    // swiftlint:disable:next optional_data_string_conversion
    private static func decodeLine(_ bytes: Data) -> String { String(decoding: bytes, as: UTF8.self) }

    private mutating func handle(line: String) -> SseEvent? {
        if line.isEmpty {
            return takeEvent()
        }
        if line.hasPrefix(":") {
            return nil
        }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex ..< colon])
            value = String(line[line.index(after: colon)...])
        } else {
            field = line
            value = ""
        }
        if value.hasPrefix(" ") {
            value.removeFirst()
        }

        switch field {
        case "event":
            eventType = value
        case "data":
            data = data.map { "\($0)\n\(value)" } ?? value
        case "id":
            // Per the SSE spec an id containing a NUL is ignored outright.
            if !value.contains("\0") {
                id = value
            }
        default:
            // `retry` and anything unrecognized are dropped rather than erroring.
            break
        }

        return nil
    }

    private mutating func takeEvent() -> SseEvent? {
        defer {
            eventType = nil
            data = nil
            id = nil
        }
        guard let data else { return nil }
        return SseEvent(event: eventType, data: data, id: id)
    }
}
