//! Serializable request/response data model for the route planner.
//!
//! These types define the JSON-facing contract shared across platforms; they
//! carry no behavior beyond (de)serialization.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyConstraint {
    LocalRequired,
    LocalPreferred,
    CloudAllowed,
    CloudRequired,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CloudConstraint {
    Forbidden,
    Allowed,
    Required,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OptimizeFor {
    Privacy,
    Latency,
    Cost,
    Balanced,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderType {
    Local,
    Edge,
    Cloud,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RouteFailureCode {
    CapabilityMismatch,
    Offline,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RejectionReasonCode {
    TaskNotSupported,
    RunNotSupported,
    PrivacyConstraint,
    CloudConstraint,
    Offline,
    CapabilityUnavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RoutingTask {
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RoutingConstraints {
    #[serde(default)]
    pub privacy: Option<PrivacyConstraint>,
    #[serde(default)]
    pub cloud: Option<CloudConstraint>,
    #[serde(default)]
    pub network_online: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RoutingPreferences {
    #[serde(default)]
    pub optimize_for: Option<OptimizeFor>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRunSupport {
    pub run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPrivacy {
    pub data_leaves_device: bool,
    #[serde(default)]
    pub regions: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderDescriptor {
    pub id: String,
    #[serde(rename = "type")]
    pub provider_type: ProviderType,
    pub supports: ProviderRunSupport,
    pub tasks: Vec<String>,
    #[serde(default)]
    pub privacy: Option<ProviderPrivacy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCapabilitySnapshot {
    pub available: bool,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInput {
    pub descriptor: ProviderDescriptor,
    pub capabilities: ProviderCapabilitySnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlanRouteInput {
    pub task: RoutingTask,
    pub constraints: RoutingConstraints,
    #[serde(default)]
    pub preferences: RoutingPreferences,
    pub providers: Vec<ProviderInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RouteCandidate {
    pub provider_id: String,
    pub order: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RejectionReason {
    pub code: RejectionReasonCode,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RejectedProvider {
    pub provider_id: String,
    pub reasons: Vec<RejectionReason>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RouteExplanation {
    pub summary: String,
    #[serde(default)]
    pub selected_provider_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RoutePlan {
    #[serde(default)]
    pub selected_provider_id: Option<String>,
    #[serde(default)]
    pub fallback_provider_ids: Vec<String>,
    #[serde(default)]
    pub candidates: Vec<RouteCandidate>,
    #[serde(default)]
    pub rejected_providers: Vec<RejectedProvider>,
    #[serde(default)]
    pub failure_code: Option<RouteFailureCode>,
    pub explanation: RouteExplanation,
}
