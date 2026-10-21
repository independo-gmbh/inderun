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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interaction_mode: Option<InteractionMode>,

    /// The resolved model profile the request routes within. Absent means the built-in 'auto'
    /// profile: no allow-list, and ordering by placement and preference alone. When present,
    /// providers whose id is not in targetIds are rejected with 'not_in_model_profile', and the
    /// position in targetIds ranks the survivors after placement and before preferences. Ids
    /// that name no registered provider are ignored.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_profile: Option<ModelProfile>,

    /// Soft route ordering preferences applied after hard filtering.
    pub preferences: Preferences,

    /// Static descriptors plus dynamic capability checks for planning. Both shapes are the
    /// provider schemas themselves, shared by $ref, so the planner reads exactly what
    /// checkCapabilities() reports.
    pub providers: Vec<Provider>,

    /// Task descriptor for provider task matching: the kind plus the requirements routing can
    /// check against declared capabilities. Absent requirement fields are never checked, so a
    /// text request carries the kind alone.
    pub task: Task,
}

/// Hard routing constraints evaluated before provider selection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Constraints {
    /// Cloud execution constraint.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloud: Option<Cloud>,

    /// Current connectivity snapshot used for cloud route planning.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network_online: Option<bool>,

    /// Privacy requirement or preference for execution placement.
    #[serde(skip_serializing_if = "Option::is_none")]
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
    #[serde(skip_serializing_if = "Option::is_none")]
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cancellation_available: Option<bool>,

    /// Why the provider is unavailable, when available is false.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,

    /// Whether the provider can stream (Mode 2) on this host right now. Absent inherits the
    /// static descriptor.supports.streaming value; only set it when the host takes streaming
    /// away from a provider that otherwise declares it. Never null.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub streaming_available: Option<bool>,

    /// Why streaming is unavailable, when streamingAvailable is false. Absent lets the route
    /// planner synthesize a default message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub streaming_unavailable_reason: Option<String>,

    /// Per-task overrides of the provider-level check, for tasks whose availability differs on
    /// this host, e.g. a voice that is not installed. Every field of an entry is optional and
    /// absent inherits the provider-level value; a false at either level wins.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_capabilities: Option<Vec<ProviderTaskAvailability>>,
}

/// The live check for one task kind.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderTaskAvailability {
    /// Whether the task can run on this host right now. Absent inherits the provider-level
    /// available. Never null.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub available: Option<bool>,

    /// Whether cancellation is honored for this task right now. Absent inherits. Never null.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cancellation_available: Option<bool>,

    /// The task kind this entry describes.
    pub kind: String,

    /// BCP 47 locales available for this task right now. Absent means the provider cannot
    /// enumerate them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub locales: Option<Vec<String>>,

    /// Why the task is unavailable, when available is false.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,

    /// Whether the task can stream on this host right now. Absent inherits. Never null.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub streaming_available: Option<bool>,

    /// Why streaming is unavailable for this task, when streamingAvailable is false.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub streaming_unavailable_reason: Option<String>,

    /// Voices available for this task right now. Absent means the provider cannot enumerate
    /// them; a request that requires a voice then never routes to it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub voices: Option<Vec<ProviderVoice>>,
}

/// Provider-neutral traits of one available voice. Carries no provider voice identifier.
///
/// The voice this candidate must use if it is attempted, chosen by the planner from the
/// provider's dynamic voice inventory. It is the best voice that satisfies the request's
/// locale, required voice traits and privacy — under local-required privacy always one that
/// keeps data on the device — ranked by preferred gender, then exact locale region, then
/// on-device before network. The adapter must use a voice with exactly these traits. Absent
/// when the request names no locale or voice, or the provider does not list its voices; the
/// adapter then chooses itself under the same rules.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderVoice {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gender: Option<VoiceGender>,

    /// BCP 47 locale the voice speaks.
    pub locale: String,

    /// Whether using the voice sends data off the device. Absent inherits the task's privacy
    /// posture.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network_required: Option<bool>,
}

/// Perceived gender of a voice, as the platform reports it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VoiceGender {
    Female,

    Male,

    Neutral,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limits: Option<ProviderLimits>,

    /// The model this provider instance is bound to, when it can name one. Cloud providers
    /// report the model id they send; platform-managed models report an opaque platform alias
    /// rather than a guessed weight name. Absent means the provider cannot name its model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,

    /// Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
    /// or edge provider is treated as keeping data on the device and a cloud provider as sending
    /// it off.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub privacy: Option<ProviderPrivacy>,

    /// How a streaming provider delivers incremental output: individual tokens, larger chunks,
    /// or whole snapshots. Absent for providers that do not stream.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub streaming_style: Option<StreamingStyle>,

    /// Interaction modes and features the provider statically declares.
    pub supports: ProviderSupports,

    /// What the provider can do for each task: accepted inputs, interaction modes, output
    /// deliveries and formats, cancellation, locales and privacy. When present it is
    /// authoritative for routing and must list every task the provider serves. When absent (a
    /// legacy descriptor), routing infers exactly one entry — 'text_to_text' with text input,
    /// inline output, run/stream from supports and cancel from cancel — if tasks contains
    /// 'text_to_text', and nothing for any other task: a legacy descriptor is never treated as
    /// capable of a non-text task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_capabilities: Option<Vec<ProviderTaskCapability>>,

    /// Task kinds the provider supports, e.g. 'text_to_text'. When taskCapabilities is present
    /// it must describe the same kinds and is what routing reads; without it, routing infers
    /// capabilities for 'text_to_text' alone (see taskCapabilities).
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
///
/// Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
/// when stopping playback is immediate but a synthesis request cannot be aborted.
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_audio_seconds: Option<i64>,

    /// Largest accepted image, in bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_image_bytes: Option<i64>,

    /// Largest accepted input, in tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_input_tokens: Option<i64>,

    /// Largest output the provider produces, in tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<i64>,
}

/// Data-egress posture, used to enforce local and cloud routing rules. Absent means a local
/// or edge provider is treated as keeping data on the device and a cloud provider as sending
/// it off.
///
/// Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
/// provider whose speech synthesis uses a network service. Absent inherits
/// descriptor.privacy.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPrivacy {
    /// Whether request content leaves the device.
    pub data_leaves_device: bool,

    /// Geographic regions where a cloud provider processes data.
    #[serde(skip_serializing_if = "Option::is_none")]
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

/// The provider's static capabilities for one task kind.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderTaskCapability {
    /// Cancellation guarantee for this task. It may differ from the provider-level cancel, e.g.
    /// when stopping playback is immediate but a synthesis request cannot be aborted.
    pub cancel: CancelSemantics,

    /// Input media kinds the provider accepts for this task.
    pub inputs: Vec<TaskInputKind>,

    /// Interaction modes the provider supports for this task.
    pub interaction: ProviderTaskInteraction,

    /// The task kind this entry describes, e.g. 'text_to_speech'.
    pub kind: String,

    /// BCP 47 locales the provider can serve for this task, when it knows them statically.
    /// Absent means unknown; the dynamic check may report them instead.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub locales: Option<Vec<String>>,

    /// How results of this task can be delivered. A provider lists only what it really produces:
    /// a provider that can only play audio lists 'playback' and never 'artifact'.
    pub outputs: Vec<ProviderTaskOutput>,

    /// Data-egress posture for this task when it differs from the provider-level privacy, e.g. a
    /// provider whose speech synthesis uses a network service. Absent inherits
    /// descriptor.privacy.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub privacy: Option<ProviderPrivacy>,
}

/// A kind of input medium a task consumes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskInputKind {
    Audio,

    Image,

    Text,
}

/// Interaction modes the provider supports for this task.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderTaskInteraction {
    /// Whether the provider supports Mode 1 run for this task.
    pub run: bool,

    /// Whether the provider supports Mode 2 stream for this task.
    pub stream: bool,
}

/// One way the provider can deliver a task's result.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderTaskOutput {
    pub delivery: OutputDelivery,

    /// Media types the provider can produce with this delivery, e.g. 'audio/wav'. Absent means
    /// the provider does not declare them; a request that requires specific media types never
    /// routes to such an output.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_types: Option<Vec<String>>,
}

/// How a task's result reaches the application: 'inline' content in the result (text),
/// 'playback' as a managed, audible effect on the device with no retrievable bytes, or
/// 'artifact' as retrievable media.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputDelivery {
    Artifact,

    Inline,

    Playback,
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

/// Task descriptor for provider task matching: the kind plus the requirements routing can
/// check against declared capabilities. Absent requirement fields are never checked, so a
/// text request carries the kind alone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Task {
    /// The output delivery the request requires. Absent for text, whose delivery is implicitly
    /// inline.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivery: Option<DeliveryRequirement>,

    /// Input media kinds the request carries. Every one must be accepted by the provider's task
    /// capability. The SDKs send ['text'] for text_to_text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inputs: Option<Vec<TaskInputKind>>,

    /// The task kind, matched against the providers' task capabilities.
    pub kind: String,

    /// The locale the request requires. Under 'language' matching the region is a preference: a
    /// provider known to offer the exact tag ranks ahead of an otherwise equal one. A provider
    /// that cannot enumerate its locales is not rejected on this basis; it must fail before
    /// committing instead.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub locale: Option<LocaleRequirement>,

    /// Voice traits the request asks for. Only a 'required' voice can reject a provider; a
    /// 'preferred' one shapes which listed voice the plan binds a candidate to, always within
    /// the request's privacy policy.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub voice: Option<VoiceRequirement>,
}

/// The output delivery the request requires. Absent for text, whose delivery is implicitly
/// inline.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryRequirement {
    /// Acceptable media types; the provider must declare at least one for the requested
    /// delivery. Absent means any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_types: Option<Vec<String>>,

    pub mode: OutputDelivery,
}

/// The locale the request requires. Under 'language' matching the region is a preference: a
/// provider known to offer the exact tag ranks ahead of an otherwise equal one. A provider
/// that cannot enumerate its locales is not rejected on this basis; it must fail before
/// committing instead.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LocaleRequirement {
    /// 'exact' requires the full tag; 'language' requires only the primary language subtag and
    /// treats the region as a preference.
    #[serde(rename = "match")]
    pub locale_requirement_match: LocaleMatch,

    /// BCP 47 tag.
    pub tag: String,
}

/// 'exact' requires the full tag; 'language' requires only the primary language subtag and
/// treats the region as a preference.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LocaleMatch {
    Exact,

    Language,
}

/// Voice traits the request asks for. Only a 'required' voice can reject a provider; a
/// 'preferred' one shapes which listed voice the plan binds a candidate to, always within
/// the request's privacy policy.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VoiceRequirement {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gender: Option<VoiceGender>,

    /// 'required' takes part in routing; 'preferred' does not.
    pub requirement: RequirementLevel,
}

/// 'required' takes part in routing; 'preferred' does not.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequirementLevel {
    Preferred,

    Required,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure_code: Option<FailureCode>,

    /// Fallback provider IDs ordered after the primary selection.
    pub fallback_provider_ids: Vec<String>,

    /// Providers filtered out during planning together with machine-readable reasons.
    pub rejected_providers: Vec<RejectedProvider>,

    /// Chosen primary provider ID, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_provider_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub order: i64,

    pub provider_id: String,

    /// The voice this candidate must use if it is attempted, chosen by the planner from the
    /// provider's dynamic voice inventory. It is the best voice that satisfies the request's
    /// locale, required voice traits and privacy — under local-required privacy always one that
    /// keeps data on the device — ranked by preferred gender, then exact locale region, then
    /// on-device before network. The adapter must use a voice with exactly these traits. Absent
    /// when the request names no locale or voice, or the provider does not list its voices; the
    /// adapter then chooses itself under the same rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub voice: Option<ProviderVoice>,
}

/// Human-readable selection or failure explanation suitable for telemetry/debugging.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Explanation {
    #[serde(skip_serializing_if = "Option::is_none")]
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
    /// list this provider. 'input_not_supported', 'output_delivery_not_supported',
    /// 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
    /// provider's task capability lacks an input kind, output delivery, media type, locale or
    /// voice the request requires.
    pub code: Code,

    pub message: String,
}

/// Normalized rejection reason. 'streaming_not_supported' means the descriptor does not
/// statically declare Mode-2 streaming; 'streaming_unavailable' means it declares streaming
/// but the dynamic capability snapshot reports it cannot stream in the current host
/// environment. 'not_in_model_profile' means the request named a model profile that does not
/// list this provider. 'input_not_supported', 'output_delivery_not_supported',
/// 'output_format_not_supported', 'locale_not_supported' and 'voice_not_available' mean the
/// provider's task capability lacks an input kind, output delivery, media type, locale or
/// voice the request requires.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Code {
    #[serde(rename = "capability_unavailable")]
    CapabilityUnavailable,

    #[serde(rename = "cloud_constraint")]
    CloudConstraint,

    #[serde(rename = "input_not_supported")]
    InputNotSupported,

    #[serde(rename = "locale_not_supported")]
    LocaleNotSupported,

    #[serde(rename = "not_in_model_profile")]
    NotInModelProfile,

    Offline,

    #[serde(rename = "output_delivery_not_supported")]
    OutputDeliveryNotSupported,

    #[serde(rename = "output_format_not_supported")]
    OutputFormatNotSupported,

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

    #[serde(rename = "voice_not_available")]
    VoiceNotAvailable,
}
