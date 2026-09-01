//! Shared Rust route-planning core for IndeRun.
//!
//! The crate is organized into focused modules:
//!
//! - [`model`] — the serializable request/response data types.
//! - [`planner`] — the deterministic [`plan_route`] algorithm.
//! - `ffi` — the C, Android JNI, and wasm boundaries that expose the planner.
//!
//! The data model and [`plan_route`] are re-exported at the crate root so the
//! public API stays flat (e.g. `inderun_route_core::ProviderDescriptor`).

// An Android library with no `Java_..._planRouteJsonNative` export loads fine and
// then fails at the first native call, which is exactly the silent degradation
// this crate exists to remove. Fail at build time instead.
#[cfg(all(target_os = "android", not(feature = "jni-bindings")))]
compile_error!(
    "Building for Android without the `jni-bindings` feature produces a library with no JNI \
     entry point. Build it with scripts/build-route-core-android.mjs."
);

mod ffi;
mod model;
mod planner;

pub use model::*;
pub use planner::plan_route;

#[cfg(test)]
mod tests;
