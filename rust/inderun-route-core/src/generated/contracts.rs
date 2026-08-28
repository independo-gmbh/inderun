/* This file was generated from JSON Schema using quicktype. Do not edit by hand. */

use serde::{Deserialize, Serialize};

/// Pure data input contract for deterministic shared-core route planning.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoutePlannerInput {
    /// Hard routing constraints evaluated before provider selection.
    pub constraints: Constraints,

    /// Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
    /// produced before this field existed keep their exact Mode-1 semantics. The mode filters
    /// eligible providers; it never changes candidate ordering.
    pub interaction_mode: Option<InteractionMode>,

    /// Soft route ordering preferences applied after hard filtering.
    pub preferences: Preferences,

    /// Static descriptors plus dynamic capability snapshots for planning.
    pub providers: Vec<Provider>,

    /// Minimal task descriptor for provider task matching.
    pub task: Task,
}

/// Hard routing constraints evaluated before provider selection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Constraints {
    /// Cloud execution constraint.
    pub cloud: Option<Cloud>,

    /// Current connectivity snapshot used for cloud route planning.
    pub network_online: Option<bool>,

    /// Privacy requirement or preference for execution placement.
    pub privacy: Option<PrivacyEnum>,
}

/// Cloud execution constraint.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Cloud {
    Allowed,

    Forbidden,

    Required,
}

/// Privacy requirement or preference for execution placement.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyEnum {
    #[serde(rename = "cloud_allowed")]
    CloudAllowed,

    #[serde(rename = "cloud_required")]
    CloudRequired,

    #[serde(rename = "local_preferred")]
    LocalPreferred,

    #[serde(rename = "local_required")]
    LocalRequired,
}

/// Interaction mode the caller is requesting. Absent means 'run' (Mode 1), so planner inputs
/// produced before this field existed keep their exact Mode-1 semantics. The mode filters
/// eligible providers; it never changes candidate ordering.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InteractionMode {
    Run,

    Stream,
}

/// Soft route ordering preferences applied after hard filtering.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preferences {
    /// Primary optimization goal when multiple providers remain eligible.
    pub optimize_for: Option<OptimizeFor>,
}

/// Primary optimization goal when multiple providers remain eligible.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OptimizeFor {
    Balanced,

    Cost,

    Latency,

    Privacy,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Provider {
    pub capabilities: Capabilities,

    pub descriptor: Descriptor,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub available: bool,

    /// Whether cancellation is honored right now in this host environment. Absent inherits the
    /// static descriptor.cancel value (any value other than 'none' means available).
    pub cancellation_available: Option<bool>,

    pub reason: Option<String>,

    /// Whether the provider can stream right now in this host environment. Absent inherits the
    /// static descriptor.supports.streaming value.
    pub streaming_available: Option<bool>,

    /// Human-readable explanation used when streamingAvailable is false. Absent lets the planner
    /// synthesize a default message.
    pub streaming_unavailable_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Descriptor {
    /// Cancellation guarantee the provider offers. Carried for route explanations and telemetry;
    /// the planner does not filter on it.
    pub cancel: Option<Cancel>,

    pub id: String,

    /// Descriptor privacy metadata used to enforce local/cloud routing rules.
    pub privacy: Option<PrivacyClass>,

    pub supports: Supports,

    pub tasks: Vec<String>,

    #[serde(rename = "type")]
    pub descriptor_type: Type,
}

/// Cancellation guarantee the provider offers. Carried for route explanations and telemetry;
/// the planner does not filter on it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Cancel {
    #[serde(rename = "none")]
    CancelNone,

    Hard,

    Soft,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Type {
    Cloud,

    Edge,

    Local,
}

/// Descriptor privacy metadata used to enforce local/cloud routing rules.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrivacyClass {
    pub data_leaves_device: bool,

    pub regions: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Supports {
    pub run: bool,

    /// Whether the provider statically declares Mode-2 streaming. Absent is treated as false: a
    /// descriptor that predates this field cannot be assumed to stream.
    pub streaming: Option<bool>,
}

/// Minimal task descriptor for provider task matching.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Task {
    pub kind: String,
}

/// Deterministic shared-core Mode-1 route planning result.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoutePlan {
    /// Eligible candidates in deterministic order.
    pub candidates: Vec<Candidate>,

    /// Human-readable selection or failure explanation suitable for telemetry/debugging.
    pub explanation: Explanation,

    /// Normalized routing failure class when no provider is selected.
    pub failure_code: Option<FailureCode>,

    /// Fallback provider IDs ordered after the primary selection.
    pub fallback_provider_ids: Vec<String>,

    /// Providers filtered out during planning together with machine-readable reasons.
    pub rejected_providers: Vec<RejectedProvider>,

    /// Chosen primary provider ID, if any.
    pub selected_provider_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub order: i64,

    pub provider_id: String,
}

/// Human-readable selection or failure explanation suitable for telemetry/debugging.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Explanation {
    pub selected_provider_id: Option<String>,

    pub summary: String,
}

/// Normalized routing failure class when no provider is selected.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureCode {
    #[serde(rename = "capability_mismatch")]
    CapabilityMismatch,

    Offline,

    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RejectedProvider {
    pub provider_id: String,

    pub reasons: Vec<Reason>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Reason {
    /// Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
    /// statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
    /// but the dynamic capability snapshot reports it cannot stream in the current host
    /// environment.
    pub code: Code,

    pub message: String,
}

/// Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
/// statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
/// but the dynamic capability snapshot reports it cannot stream in the current host
/// environment.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Code {
    #[serde(rename = "capability_unavailable")]
    CapabilityUnavailable,

    #[serde(rename = "cloud_constraint")]
    CloudConstraint,

    Offline,

    #[serde(rename = "privacy_constraint")]
    PrivacyConstraint,

    #[serde(rename = "run_not_supported")]
    RunNotSupported,

    #[serde(rename = "streaming_not_supported")]
    StreamingNotSupported,

    #[serde(rename = "streaming_unavailable")]
    StreamingUnavailable,

    #[serde(rename = "task_not_supported")]
    TaskNotSupported,
}
