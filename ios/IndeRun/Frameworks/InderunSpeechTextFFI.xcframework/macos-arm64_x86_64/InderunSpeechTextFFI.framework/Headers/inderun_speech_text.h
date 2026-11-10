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

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Rewrites speech text into its spoken form for `locale` (German and English; any
 * other locale returns the text unchanged). `text` is `text_len` bytes of UTF-8 and may
 * contain U+0000, which would end a C string early; `text` may be NULL when
 * `text_len` is 0. `locale` is a NUL-terminated UTF-8 string.
 *
 * Returns UTF-8 bytes that are not NUL-terminated and writes their length to
 * `out_len`. Never returns NULL. A NULL argument or invalid UTF-8 yields an empty
 * result.
 *
 * The caller owns the returned buffer and must release it with
 * `inderun_speech_text_free`, passing the length from `out_len`. Freeing it any
 * other way is undefined: it was allocated by Rust.
 */
uint8_t *inderun_normalize_speech_text(const uint8_t *text, size_t text_len,
                                       const char *locale, size_t *out_len);

/*
 * Releases a buffer previously returned by `inderun_normalize_speech_text`, with
 * the length it reported. NULL-safe. Passing anything else, a different length,
 * or the same pointer twice, is undefined.
 */
void inderun_speech_text_free(uint8_t *value, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* INDERUN_SPEECH_TEXT_H */
