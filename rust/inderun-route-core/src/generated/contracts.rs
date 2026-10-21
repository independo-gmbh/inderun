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

    /// The resolved model profile the request routes within. Absent means the built-in 'auto'
    /// profile: no allow-list, and ordering by placement and preference alone. When present,
    /// providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the
    /// position in targetIds ranks the survivors after placement and before preferences. Ids
    /// that name no registered provider are ignored.
    pub model_profile: Option<ModelProfile>,

    /// Soft route ordering preferences applied after hard filtering.
    pub preferences: Preferences,

    /// Static descriptors plus dynamic capability checks for planning. Both shapes are the
    /// provider schemas themselves, shared by $ref, so the planner reads exactly what
    /// checkCapabilities() reports.
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
    pub privacy: Option<Privacy>,
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
pub enum Privacy {
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

/// The resolved model profile the request routes within. Absent means the built-in 'auto'
/// profile: no allow-list, and ordering by placement and preference alone. When present,
/// providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the
/// position in targetIds ranks the survivors after placement and before preferences. Ids
/// that name no registered provider are ignored.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProfile {
    /// Profile name, carried for explanations.
    pub name: String,

    /// Provider ids in profile order.
    pub target_ids: Vec<String>,
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
    /// The provider's live capability check, already folded by the engine (for example,
    /// streamingAvailable is false when the provider declares streaming but does not implement
    /// it).
    pub capabilities: ProviderDynamicCapabilities,

    /// The provider's static capability declaration.
    pub descriptor: ProviderDescriptor,
}

/// The provider's live capability check, already folded by the engine (for example,
/// streamingAvailable is false when the provider declares streaming but does not implement
/// it).
///
/// A provider's live capability check, evaluated on the current host when routing or when
/// checkCapabilities() is called. Unlike the descriptor it can change between calls.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderDynamicCapabilities {
    /// Whether the provider is available and functional on this host right now.
    pub available: bool,

    /// Whether cancellation is honored on this host right now. Absent inherits the static
    /// descriptor.cancel value: any value other than 'none' means available. Never null.
    pub cancellation_available: Option<bool>,

    /// Why the provider is unavailable, when available is false.
    pub reason: Option<String>,

    /// Whether the provider can stream (Mode 2) on this host right now. Absent inherits the
    /// static descriptor.supports.streaming value; only set it when the host takes streaming
    /// away from a provider that otherwise declares it. Never null.
    pub streaming_available: Option<bool>,

    /// Why streaming is unavailable, when streamingAvailable is false. Absent lets the route
    /// planner synthesize a default message.
    pub streaming_unavailable_reason: Option<String>,
}

/// The provider's static capability declaration.
///
/// A provider's static capability declaration: identity, placement, transport, supported
/// interaction modes and tasks, cancellation guarantee, resource limits and privacy posture.
/// It does not change while the provider is registered. The route planner,
/// checkCapabilities() and execution provenance all read this one shape.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderDescriptor {
    /// Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
    /// reading locally while remote work may continue, 'none' means cancellation is unsupported.
    /// Independently of this value, the engine delivers no event after a cancel.
    pub cancel: CancelSemantics,

    /// Unique identifier of the provider instance (a target), e.g. 'apple_foundation_models' or
    /// 'openai_compatible_cloud:gpt-5-mini'. Model profiles list targets by this id.
    pub id: String,

    /// Optional input and output resource limits.
    pub limits: Option<ProviderLimits>,

    /// The model this provider instance is bound to, when it can name one. Cloud providers
    /// report the model id they send; platform-managed models report an opaque platform alias
    /// rather than a guessed weight name. Absent means the provider cannot name its model.
    pub model: Option<String>,

    /// Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
    /// or edge provider is treated as keeping data on the device and a cloud provider as sending
    /// it off.
    pub privacy: Option<ProviderPrivacy>,

    /// How a streaming provider delivers incremental output: individual tokens, larger chunks,
    /// or whole snapshots. Absent for providers that do not stream.
    pub streaming_style: Option<StreamingStyle>,

    /// Interaction modes and features the provider statically declares.
    pub supports: ProviderSupports,

    /// Task kinds the provider supports, e.g. 'text_to_text'.
    pub tasks: Vec<String>,

    /// How the engine reaches the provider: in-process runtime, operating-system service,
    /// buffered HTTP, server-sent events, or a realtime connection.
    pub transport: ProviderTransport,

    /// Execution placement: 'local' (on the device), 'edge', or 'cloud'.
    #[serde(rename = "type")]
    pub provider_descriptor_type: ProviderType,
}

/// Cancellation guarantee: 'hard' stops processing including remote work, 'soft' stops
/// reading locally while remote work may continue, 'none' means cancellation is unsupported.
/// Independently of this value, the engine delivers no event after a cancel.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CancelSemantics {
    #[serde(rename = "none")]
    CancelSemanticsNone,

    Hard,

    Soft,
}

/// Optional input and output resource limits.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderLimits {
    /// Longest accepted or produced audio, in seconds.
    pub max_audio_seconds: Option<i64>,

    /// Largest accepted image, in bytes.
    pub max_image_bytes: Option<i64>,

    /// Largest accepted input, in tokens.
    pub max_input_tokens: Option<i64>,

    /// Largest output the provider produces, in tokens.
    pub max_output_tokens: Option<i64>,
}

/// Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
/// or edge provider is treated as keeping data on the device and a cloud provider as sending
/// it off.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPrivacy {
    /// Whether request content leaves the device.
    pub data_leaves_device: bool,

    /// Geographic regions where a cloud provider processes data.
    pub regions: Option<Vec<String>>,
}

/// Execution placement: 'local' (on the device), 'edge', or 'cloud'.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderType {
    Cloud,

    Edge,

    Local,
}

/// How a streaming provider delivers incremental output: individual tokens, larger chunks,
/// or whole snapshots. Absent for providers that do not stream.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamingStyle {
    Chunks,

    Snapshots,

    Tokens,
}

/// Interaction modes and features the provider statically declares.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSupports {
    /// Whether the provider accepts non-text inputs such as images or audio.
    pub multimodal: bool,

    /// Whether the provider supports Mode 3 realtime sessions. Reserved; no engine implements
    /// Mode 3 yet.
    pub realtime: bool,

    /// Whether the provider emits reasoning events alongside content.
    pub reasoning_events: bool,

    /// Whether the provider supports Mode 1 run (request/response).
    pub run: bool,

    /// Whether the provider supports Mode 2 stream. A provider that declares it must also
    /// implement the streaming adapter; the engines report it as unavailable otherwise.
    pub streaming: bool,

    /// Whether the provider supports structured output constrained by a JSON schema.
    pub structured_output: bool,

    /// Whether the provider supports tool calling.
    pub tools: bool,
}

/// How the engine reaches the provider: in-process runtime, operating-system service,
/// buffered HTTP, server-sent events, or a realtime connection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderTransport {
    Http,

    #[serde(rename = "in_process")]
    InProcess,

    Realtime,

    Sse,

    #[serde(rename = "system_service")]
    SystemService,
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
    /// environment. 'not_in_model_profile' means the request named a model profile that does not
    /// list this provider.
    pub code: Code,

    pub message: String,
}

/// Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
/// statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
/// but the dynamic capability snapshot reports it cannot stream in the current host
/// environment. 'not_in_model_profile' means the request named a model profile that does not
/// list this provider.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Code {
    #[serde(rename = "capability_unavailable")]
    CapabilityUnavailable,

    #[serde(rename = "cloud_constraint")]
    CloudConstraint,

    #[serde(rename = "not_in_model_profile")]
    NotInModelProfile,

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
