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

mod ffi;
mod model;
mod planner;

pub use model::*;
pub use planner::plan_route;

#[cfg(test)]
mod tests;
