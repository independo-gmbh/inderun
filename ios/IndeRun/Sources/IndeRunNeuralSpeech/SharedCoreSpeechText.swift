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
        text.withCString { textPointer in
            locale.withCString { localePointer in
                guard let raw = inderun_normalize_speech_text(textPointer, localePointer) else { return "" }
                // The buffer was allocated by Rust and is ours to release.
                defer { inderun_speech_text_free(raw) }
                return String(cString: raw)
            }
        }
    }
}
