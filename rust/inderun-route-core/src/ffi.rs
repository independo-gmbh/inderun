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

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn plan_route_json(input_json: &str) -> Result<String, JsValue> {
    plan_route_json_string(input_json).map_err(JsValue::from)
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
