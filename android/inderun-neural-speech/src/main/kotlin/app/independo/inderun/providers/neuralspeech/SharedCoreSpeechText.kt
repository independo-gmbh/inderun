package app.independo.inderun.providers.neuralspeech

/**
 * Rewrites speech text into its spoken form with the shared Rust crate (the same
 * `normalize_speech_text` the Web and Swift SDKs call), packaged as this module's own native library
 * `inderun_speech_text`, so apps that do not use neural speech do not carry it.
 */
internal object SharedCoreSpeechText {
    @Volatile
    private var nativeLoaded = false

    /**
     * Normalizes [text] for [locale] (German only; any other locale comes back unchanged).
     *
     * @throws UnsatisfiedLinkError when the native library is not packaged or not on
     *   `java.library.path`.
     * @throws RuntimeException when the JNI call itself fails.
     */
    fun normalize(text: String, locale: String): String {
        ensureLoaded()
        return normalizeNative(text, locale)
    }

    @JvmStatic
    private external fun normalizeNative(text: String, locale: String): String

    @Synchronized
    private fun ensureLoaded() {
        if (nativeLoaded) return
        System.loadLibrary("inderun_speech_text")
        nativeLoaded = true
    }
}
