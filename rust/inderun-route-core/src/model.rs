//! Route-planner data model.
//!
//! These types are generated from the JSON Schema contracts by `pnpm generate`
//! (quicktype) into `generated/contracts.rs`, from
//! `contracts/schemas/route-planner-input.schema.json` and
//! `contracts/schemas/route-plan.schema.json`. They are the same contract types
//! bound by the TypeScript, Kotlin, and Swift packages, so a schema change
//! surfaces across every language on the next `pnpm generate`.
//!
//! Do not edit `generated/contracts.rs` by hand; change the schemas and
//! regenerate.

#[allow(clippy::all)]
mod generated {
    include!("generated/contracts.rs");
}

pub use generated::*;
