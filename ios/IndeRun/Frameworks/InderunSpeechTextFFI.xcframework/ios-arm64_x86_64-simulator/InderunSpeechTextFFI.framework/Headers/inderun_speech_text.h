/*
 * C interface to the shared IndeRun speech text normalizer.
 *
 * Hand-written rather than generated: the surface is two functions and has to
 * stay in sync with `src/ffi.rs`, where the same two symbols are defined with
 * `#[unsafe(no_mangle)] pub unsafe extern "C"` under the `speech-text` feature.
 *
 * This header is packaged into the InderunSpeechTextFFI XCFramework built by
 * `scripts/build-route-core-apple.mjs`, separate from the planner's, so an app
 * that never speaks does not carry the normalizer. It must never declare a symbol
 * of `inderun_route_core.h`: a Swift target that sees both modules would find the
 * name ambiguous. That is why the buffer is released by its own
 * `inderun_speech_text_free` rather than the planner's `inderun_free_string`.
 */

#ifndef INDERUN_SPEECH_TEXT_H
#define INDERUN_SPEECH_TEXT_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Rewrites speech text into its spoken form for `locale` (German only; any other
 * locale returns the text unchanged). Both arguments are NUL-terminated UTF-8
 * strings.
 *
 * Never returns NULL. A NULL argument or invalid UTF-8 yields an empty string.
 *
 * The caller owns the returned buffer and must release it with
 * `inderun_speech_text_free`. Freeing it any other way is undefined: it was
 * allocated by Rust.
 */
char *inderun_normalize_speech_text(const char *text, const char *locale);

/*
 * Releases a string previously returned by `inderun_normalize_speech_text`.
 * NULL-safe. Passing anything else, or the same pointer twice, is undefined.
 */
void inderun_speech_text_free(char *value);

#ifdef __cplusplus
}
#endif

#endif /* INDERUN_SPEECH_TEXT_H */
