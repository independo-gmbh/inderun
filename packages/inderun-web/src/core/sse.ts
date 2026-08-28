/**
 * A single dispatched server-sent event.
 *
 * `event` and `id` are `undefined` when the stream did not carry those fields.
 * `data` is the accumulated data payload with its trailing newline removed, and
 * is passed through verbatim — sentinels such as OpenAI's `[DONE]` are the
 * caller's concern, not the framing layer's.
 */
export interface SseEvent {
  event?: string;
  data: string;
  id?: string;
}

/**
 * Frames a raw byte stream into server-sent events.
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
 * Chunk boundaries are meaningless: this decodes incrementally (`stream: true`)
 * so a boundary may fall inside a multi-byte UTF-8 sequence or mid-line.
 *
 * Held to `contracts/fixtures/streaming/sse-framing.json` together with the
 * Swift and Kotlin implementations of the same protocol.
 *
 * @param chunks - Raw response body chunks, in arrival order.
 */
export async function* parseSseStream(
  chunks: AsyncIterable<Uint8Array>
): AsyncGenerator<SseEvent> {
  const decoder = new TextDecoder("utf-8");
  let buffer = "";

  let eventType: string | undefined;
  let data: string | undefined;
  let id: string | undefined;

  const takeEvent = (): SseEvent | undefined => {
    const dispatched = data === undefined ? undefined : buildEvent(eventType, data, id);
    eventType = undefined;
    data = undefined;
    id = undefined;
    return dispatched;
  };

  const handleLine = (line: string): SseEvent | undefined => {
    if (line.length === 0) return takeEvent();
    if (line.startsWith(":")) return undefined;

    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);

    switch (field) {
      case "event":
        eventType = value;
        break;
      case "data":
        data = data === undefined ? value : `${data}\n${value}`;
        break;
      case "id":
        // Per the SSE spec an id containing a NUL is ignored outright.
        if (!value.includes("\0")) id = value;
        break;
      default:
        // `retry` and anything unrecognized are dropped rather than erroring.
        break;
    }

    return undefined;
  };

  for await (const chunk of chunks) {
    buffer += decoder.decode(chunk, { stream: true });

    for (;;) {
      const line = takeLine();
      if (line === undefined) break;
      const dispatched = handleLine(line);
      if (dispatched) yield dispatched;
    }
  }

  // A trailing bare CR is ambiguous until the stream ends: it could still have
  // been the first half of a CRLF.
  buffer += decoder.decode();
  for (;;) {
    const line = takeLine(true);
    if (line === undefined) break;
    const dispatched = handleLine(line);
    if (dispatched) yield dispatched;
  }

  function takeLine(atEnd = false): string | undefined {
    for (let index = 0; index < buffer.length; index += 1) {
      const char = buffer[index];
      if (char === "\n") {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        return line;
      }
      if (char === "\r") {
        const isLast = index === buffer.length - 1;
        // Withhold a trailing CR until we know whether an LF follows, unless
        // the stream is over and no LF can arrive.
        if (isLast && !atEnd) return undefined;
        const skip = buffer[index + 1] === "\n" ? 2 : 1;
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + skip);
        return line;
      }
    }
    return undefined;
  }
}

function buildEvent(eventType: string | undefined, data: string, id: string | undefined): SseEvent {
  return {
    ...(eventType !== undefined ? { event: eventType } : {}),
    data,
    ...(id !== undefined ? { id } : {})
  };
}
