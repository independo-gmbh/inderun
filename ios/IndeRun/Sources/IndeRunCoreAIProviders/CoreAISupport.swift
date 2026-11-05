import Foundation
#if canImport(CoreAI)
import CoreAI
#endif

/// Whether Apple Core AI can run here. Compiles without the framework: an Xcode whose SDK has no
/// `CoreAI` builds this module to a stub that is never available.
public enum CoreAISupport {
    /// The reason a Core AI runtime reports when ``isAvailable`` is `false`.
    public static let unavailableReason = "Core AI requires iOS 27 / macOS 27"

    /// `true` only when the framework was compiled in and the OS is new enough to load it.
    public static var isAvailable: Bool {
        #if canImport(CoreAI)
        if #available(iOS 27, macOS 27, *) {
            return true
        }
        return false
        #else
        return false
        #endif
    }
}
