//! Cross-platform foreign-function boundaries.
//!
//! Each entry point accepts the planner input as JSON, delegates to
//! [`plan_route`], and returns the resulting [`RoutePlan`] as JSON. The C, JNI,
//! and wasm bindings share the same JSON glue so behavior stays identical across
//! platforms.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[cfg(feature = "jni-bindings")]
use jni::EnvUnowned;
#[cfg(feature = "jni-bindings")]
use jni::errors::ThrowRuntimeExAndDefault;
#[cfg(feature = "jni-bindings")]
use jni::objects::{JClass, JString};
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

use crate::model::RoutePlannerInput;
use crate::planner::plan_route;

fn plan_route_json_string(input_json: &str) -> Result<String, String> {
    let input =
        serde_json::from_str::<RoutePlannerInput>(input_json).map_err(|error| error.to_string())?;
    let output = plan_route(input);
    serde_json::to_string(&output).map_err(|error| error.to_string())
}

/// C FFI boundary: the caller owns and must pass a valid, NUL-terminated pointer.
///
/// # Safety
/// `input_json` must be null or a valid pointer to a NUL-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inderun_plan_route_json(input_json: *const c_char) -> *mut c_char {
    if input_json.is_null() {
        return CString::new(
            serde_json::json!({
                "selectedProviderId": null,
                "fallbackProviderIds": [],
                "candidates": [],
                "rejectedProviders": [],
                "failureCode": "unavailable",
                "explanation": { "summary": "Missing planner input.", "selectedProviderId": null }
            })
            .to_string(),
        )
        .expect("CString conversion must succeed")
        .into_raw();
    }

    let input = unsafe { CStr::from_ptr(input_json) };
    let response = match input.to_str() {
        Ok(value) => plan_route_json_string(value).unwrap_or_else(error_json),
        Err(error) => error_json(error.to_string()),
    };

    CString::new(response)
        .expect("CString conversion must succeed")
        .into_raw()
}

/// C FFI boundary: takes ownership of and frees a string previously returned by this crate.
///
/// # Safety
/// `value` must be null or a pointer previously returned by `inderun_plan_route_json`
/// (and not already freed).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inderun_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = CString::from_raw(value);
    }
}

/// C FFI boundary for the speech text normalizer: [`crate::normalize_speech_text`] over two
/// C strings. A null pointer or invalid UTF-8 in either argument yields an empty string; the
/// normalizer itself never fails. The result is freed with [`inderun_speech_text_free`].
///
/// # Safety
/// `text` and `locale` must each be null or a valid pointer to a NUL-terminated C string.
#[cfg(feature = "speech-text")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inderun_normalize_speech_text(
    text: *const c_char,
    locale: *const c_char,
) -> *mut c_char {
    let normalized = if text.is_null() || locale.is_null() {
        String::new()
    } else {
        let text = unsafe { CStr::from_ptr(text) }.to_str();
        let locale = unsafe { CStr::from_ptr(locale) }.to_str();
        match (text, locale) {
            (Ok(text), Ok(locale)) => crate::normalize_speech_text(text, locale),
            _ => String::new(),
        }
    };

    // A normalized text cannot hold a NUL: the input was a C string and the rewrites add none.
    CString::new(normalized).unwrap_or_default().into_raw()
}

/// Releases a string returned by [`inderun_normalize_speech_text`]. A distinct symbol from
/// [`inderun_free_string`] so the planner's and the normalizer's Apple frameworks never export the
/// same name; both release a buffer Rust allocated.
///
/// # Safety
/// `value` must be null or a pointer returned by `inderun_normalize_speech_text` (and not already
/// freed).
#[cfg(feature = "speech-text")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inderun_speech_text_free(value: *mut c_char) {
    unsafe { inderun_free_string(value) }
}

/// JNI boundary for `SharedCoreRoutePlanner.planRouteJsonNative`.
///
/// A planner-level failure (unparseable input, unserializable plan) comes back as
/// the same JSON error shape the C boundary returns, so the Kotlin side sees one
/// vocabulary. Only a genuine JNI failure -- the JVM refusing to hand over or
/// allocate a string -- becomes a thrown Java exception, and `with_env` also
/// turns a panic into one instead of unwinding into the JVM.
#[cfg(feature = "jni-bindings")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_independo_inderun_core_SharedCoreRoutePlanner_planRouteJsonNative<
    'local,
>(
    mut unowned_env: EnvUnowned<'local>,
    _class: JClass<'local>,
    input_json: JString<'local>,
) -> JString<'local> {
    unowned_env
        .with_env(|env| -> jni::errors::Result<JString<'local>> {
            let input = input_json.try_to_string(env)?;
            let output = plan_route_json_string(&input).unwrap_or_else(error_json);
            env.new_string(&output)
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

/// JNI entry for `SharedCoreSpeechText.normalizeNative` in `:inderun-neural-speech`, exported by
/// its own library (`libinderun_speech_text`), not by the planner's: [`crate::normalize_speech_text`] over a
/// Java string pair. The normalizer itself never fails; only a JNI failure (the JVM refusing to
/// hand over or allocate a string) becomes a thrown Java exception, and `with_env` turns a panic
/// into one instead of unwinding into the JVM.
#[cfg(all(feature = "jni-bindings", feature = "speech-text"))]
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_independo_inderun_providers_neuralspeech_SharedCoreSpeechText_normalizeNative<
    'local,
>(
    mut unowned_env: EnvUnowned<'local>,
    _class: JClass<'local>,
    text: JString<'local>,
    locale: JString<'local>,
) -> JString<'local> {
    unowned_env
        .with_env(|env| -> jni::errors::Result<JString<'local>> {
            let text = text.try_to_string(env)?;
            let locale = locale.try_to_string(env)?;
            env.new_string(crate::normalize_speech_text(&text, &locale))
        })
        .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn plan_route_json(input_json: &str) -> Result<String, JsValue> {
    plan_route_json_string(input_json).map_err(JsValue::from)
}

/// Rewrites speech text into its spoken form for `locale` (German only; any other locale returns
/// the text unchanged). Never fails.
#[cfg(all(target_arch = "wasm32", feature = "speech-text"))]
#[wasm_bindgen(js_name = normalize_speech_text)]
pub fn normalize_speech_text_wasm(text: &str, locale: &str) -> String {
    crate::normalize_speech_text(text, locale)
}

fn error_json(message: String) -> String {
    serde_json::json!({
        "selectedProviderId": null,
        "fallbackProviderIds": [],
        "candidates": [],
        "rejectedProviders": [],
        "failureCode": "unavailable",
        "explanation": {
            "summary": format!("Shared route planner error: {message}"),
            "selectedProviderId": null
        }
    })
    .to_string()
}
