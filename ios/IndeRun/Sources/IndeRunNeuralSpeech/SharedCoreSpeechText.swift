import Foundation
import InderunSpeechTextFFI

/// The speech text normalizer of the shared Rust core (`rust/inderun-route-core`, feature
/// `speech-text`), through its C interface: German numbers, dates, times, money, units and
/// abbreviations become spoken words; any other locale comes back unchanged.
///
/// Linked from its own XCFramework, separate from the route planner's, so an app that never uses
/// neural speech does not carry the normalizer. The call cannot fail, and a missing symbol is a
/// link error rather than a runtime state.
enum SharedCoreSpeechText {
    static func normalize(_ text: String, locale: String) -> String {
        // Bytes plus a length rather than a C string: a C string would end at an embedded U+0000
        // and drop the rest of the text, which the Web and Android bindings keep.
        Array(text.utf8).withUnsafeBufferPointer { textBytes in
            locale.withCString { localePointer in
                var length = 0
                guard let raw = inderun_normalize_speech_text(
                    textBytes.baseAddress, textBytes.count, localePointer, &length
                ) else { return "" }
                // The buffer was allocated by Rust and is ours to release.
                defer { inderun_speech_text_free(raw, length) }
                // Rust returns valid UTF-8, so the fallback is unreachable.
                return String(bytes: UnsafeBufferPointer(start: raw, count: length), encoding: .utf8) ?? ""
            }
        }
    }
}
