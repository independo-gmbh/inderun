use crate::controls::{
    ControlCapability, ControlSupport, control_support, declaration_keeps_invariant,
    requested_controls,
};
use crate::*;

/// Test provider builder. Defaults mirror a shipped Mode-1 provider: `run: true`,
/// no streaming declared, no dynamic streaming/cancellation overrides.
struct ProviderBuilder {
    provider: Provider,
    unavailable_reason: String,
}

impl ProviderBuilder {
    fn new(id: &str, descriptor_type: ProviderType, data_leaves_device: bool) -> Self {
        let unavailable_reason = match descriptor_type {
            ProviderType::Cloud => "Cloud runtime unavailable.",
            _ => "Local runtime unavailable.",
        };
        Self {
            provider: Provider {
                descriptor: ProviderDescriptor {
                    id: id.to_string(),
                    provider_descriptor_type: descriptor_type.clone(),
                    model: None,
                    transport: match descriptor_type {
                        ProviderType::Cloud => ProviderTransport::Http,
                        _ => ProviderTransport::InProcess,
                    },
                    streaming_style: None,
                    supports: ProviderSupports {
                        run: true,
                        streaming: false,
                        realtime: false,
                        tools: false,
                        reasoning_events: false,
                        structured_output: false,
                        multimodal: false,
                    },
                    cancel: CancelSemantics::Hard,
                    tasks: vec!["text_to_text".to_string()],
                    task_capabilities: None,
                    limits: None,
                    privacy: Some(ProviderPrivacy {
                        data_leaves_device,
                        regions: None,
                    }),
                },
                capabilities: ProviderDynamicCapabilities {
                    available: true,
                    reason: None,
                    streaming_available: None,
                    streaming_unavailable_reason: None,
                    cancellation_available: None,
                    task_capabilities: None,
                },
            },
            unavailable_reason: unavailable_reason.to_string(),
        }
    }

    fn available(mut self, available: bool) -> Self {
        self.provider.capabilities.available = available;
        self.provider.capabilities.reason = (!available).then(|| self.unavailable_reason.clone());
        self
    }

    fn run(mut self, run: bool) -> Self {
        self.provider.descriptor.supports.run = run;
        self
    }

    fn streaming(mut self, streaming: bool) -> Self {
        self.provider.descriptor.supports.streaming = streaming;
        self
    }

    fn streaming_available(mut self, available: Option<bool>, reason: Option<&str>) -> Self {
        self.provider.capabilities.streaming_available = available;
        self.provider.capabilities.streaming_unavailable_reason =
            reason.map(|value| value.to_string());
        self
    }

    fn build(self) -> Provider {
        self.provider
    }
}

fn text_task() -> Task {
    Task {
        kind: "text_to_text".to_string(),
        inputs: None,
        delivery: None,
        locale: None,
        voice: None,
        controls: None,
    }
}

fn local_builder(id: &str, private: bool) -> ProviderBuilder {
    ProviderBuilder::new(id, ProviderType::Local, !private)
}

fn cloud_builder(id: &str) -> ProviderBuilder {
    ProviderBuilder::new(id, ProviderType::Cloud, true)
}

fn local_provider(id: &str, available: bool, private: bool) -> Provider {
    local_builder(id, private).available(available).build()
}

fn cloud_provider(id: &str, available: bool) -> Provider {
    cloud_builder(id).available(available).build()
}

fn plan(constraints: Constraints, preferences: Preferences, providers: Vec<Provider>) -> RoutePlan {
    plan_with_mode(None, constraints, preferences, providers)
}

fn plan_streaming(
    constraints: Constraints,
    preferences: Preferences,
    providers: Vec<Provider>,
) -> RoutePlan {
    plan_with_mode(
        Some(InteractionMode::Stream),
        constraints,
        preferences,
        providers,
    )
}

fn plan_with_mode(
    interaction_mode: Option<InteractionMode>,
    constraints: Constraints,
    preferences: Preferences,
    providers: Vec<Provider>,
) -> RoutePlan {
    plan_route(RoutePlannerInput {
        task: text_task(),
        interaction_mode,
        constraints,
        preferences,
        model_profile: None,
        providers,
    })
}

fn plan_in_profile(
    interaction_mode: Option<InteractionMode>,
    constraints: Constraints,
    preferences: Preferences,
    target_ids: &[&str],
    providers: Vec<Provider>,
) -> RoutePlan {
    plan_route(RoutePlannerInput {
        task: text_task(),
        interaction_mode,
        constraints,
        preferences,
        model_profile: Some(ModelProfile {
            name: "smart".to_string(),
            target_ids: target_ids.iter().map(|id| id.to_string()).collect(),
        }),
        providers,
    })
}

fn default_constraints() -> Constraints {
    Constraints {
        privacy: Some(Privacy::CloudAllowed),
        cloud: Some(Cloud::Allowed),
        network_online: Some(true),
    }
}

fn default_preferences() -> Preferences {
    Preferences {
        optimize_for: Some(OptimizeFor::Balanced),
    }
}

#[test]
fn selects_local_provider_before_cloud_when_local_is_preferred() {
    let plan = plan(
        Constraints {
            privacy: Some(Privacy::LocalPreferred),
            cloud: Some(Cloud::Allowed),
            network_online: Some(true),
        },
        Preferences {
            optimize_for: Some(OptimizeFor::Balanced),
        },
        vec![
            cloud_provider("cloud_b", true),
            local_provider("local_a", true, true),
        ],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("local_a"));
    assert_eq!(plan.fallback_provider_ids, vec!["cloud_b".to_string()]);
    assert!(plan.failure_code.is_none());
}

#[test]
fn rejects_cloud_providers_when_cloud_is_forbidden() {
    let plan = plan(
        Constraints {
            privacy: None,
            cloud: Some(Cloud::Forbidden),
            network_online: Some(true),
        },
        Preferences { optimize_for: None },
        vec![cloud_provider("cloud_a", true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::CapabilityMismatch));
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        Code::CloudConstraint
    );
}

#[test]
fn rejects_local_providers_when_cloud_is_required() {
    let plan = plan(
        Constraints {
            privacy: Some(Privacy::CloudRequired),
            cloud: Some(Cloud::Required),
            network_online: Some(true),
        },
        Preferences { optimize_for: None },
        vec![local_provider("local_a", true, true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::Unavailable));
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        Code::PrivacyConstraint
    );
}

#[test]
fn returns_offline_failure_for_cloud_when_host_is_offline() {
    let plan = plan(
        Constraints {
            privacy: None,
            cloud: Some(Cloud::Allowed),
            network_online: Some(false),
        },
        Preferences { optimize_for: None },
        vec![cloud_provider("cloud_a", true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::Offline));
    assert_eq!(plan.rejected_providers[0].reasons[0].code, Code::Offline);
}

#[test]
fn preserves_deterministic_fallback_order() {
    let plan = plan(
        Constraints {
            privacy: Some(Privacy::CloudAllowed),
            cloud: Some(Cloud::Allowed),
            network_online: Some(true),
        },
        Preferences {
            optimize_for: Some(OptimizeFor::Latency),
        },
        vec![
            cloud_provider("cloud_b", true),
            cloud_provider("cloud_a", true),
            local_provider("local_a", true, true),
        ],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("cloud_a"));
    assert_eq!(
        plan.fallback_provider_ids,
        vec!["cloud_b".to_string(), "local_a".to_string()]
    );
    assert_eq!(
        plan.candidates
            .iter()
            .map(|candidate| candidate.provider_id.as_str())
            .collect::<Vec<_>>(),
        vec!["cloud_a", "cloud_b", "local_a"]
    );
}

#[test]
fn rejects_unavailable_providers_with_reasons() {
    let plan = plan(
        Constraints {
            privacy: Some(Privacy::LocalRequired),
            cloud: Some(Cloud::Allowed),
            network_online: Some(true),
        },
        Preferences { optimize_for: None },
        vec![local_provider("local_a", false, true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::CapabilityMismatch));
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        Code::CapabilityUnavailable
    );
}

#[test]
fn rejects_run_only_provider_in_run_mode() {
    let plan = plan(
        default_constraints(),
        default_preferences(),
        vec![local_builder("local_a", true).run(false).build()],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        Code::RunNotSupported
    );
}

#[test]
fn run_mode_ignores_streaming_capabilities() {
    let plan = plan(
        default_constraints(),
        default_preferences(),
        vec![
            local_builder("local_a", true)
                .streaming(false)
                .streaming_available(Some(false), Some("No chunked transport."))
                .build(),
        ],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("local_a"));
    assert!(plan.rejected_providers.is_empty());
    assert_eq!(
        plan.explanation.summary,
        "Selected provider 'local_a' deterministically from 1 eligible candidate(s)."
    );
}

#[test]
fn missing_interaction_mode_defaults_to_run() {
    // Wire-level back-compat: a planner input without `interactionMode` or the
    // dynamic streaming fields must deserialize and plan as a Mode-1 run.
    let legacy = r#"{
        "task": { "kind": "text_to_text" },
        "constraints": { "privacy": "cloud_allowed", "cloud": "allowed", "networkOnline": true },
        "preferences": { "optimizeFor": "balanced" },
        "providers": [
            {
                "descriptor": {
                    "id": "local_a",
                    "type": "local",
                    "transport": "in_process",
                    "supports": {
                        "run": true, "streaming": false, "realtime": false, "tools": false,
                        "reasoningEvents": false, "structuredOutput": false, "multimodal": false
                    },
                    "cancel": "hard",
                    "tasks": ["text_to_text"]
                },
                "capabilities": { "available": true }
            }
        ]
    }"#;

    let input: RoutePlannerInput = serde_json::from_str(legacy).expect("legacy input parses");
    assert_eq!(input.interaction_mode, None);

    let plan = plan_route(input);
    assert_eq!(plan.selected_provider_id.as_deref(), Some("local_a"));
    assert_eq!(
        plan.explanation.summary,
        "Selected provider 'local_a' deterministically from 1 eligible candidate(s)."
    );
}

#[test]
fn rejects_providers_without_static_streaming_in_stream_mode() {
    let plan = plan_streaming(
        default_constraints(),
        default_preferences(),
        vec![local_builder("local_a", true).streaming(false).build()],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::CapabilityMismatch));
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        Code::StreamingNotSupported
    );
    assert_eq!(
        plan.explanation.summary,
        "No provider capable of streaming was found for task 'text_to_text'."
    );
}

#[test]
fn rejects_providers_whose_dynamic_streaming_is_disabled() {
    let plan = plan_streaming(
        default_constraints(),
        default_preferences(),
        vec![
            local_builder("local_a", true)
                .streaming(true)
                .streaming_available(Some(false), Some("Host has no chunked HTTP capability."))
                .build(),
        ],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::CapabilityMismatch));
    let reason = &plan.rejected_providers[0].reasons[0];
    assert_eq!(reason.code, Code::StreamingUnavailable);
    assert_eq!(reason.message, "Host has no chunked HTTP capability.");
}

#[test]
fn absent_dynamic_streaming_flag_inherits_static_capability() {
    let plan = plan_streaming(
        default_constraints(),
        default_preferences(),
        vec![local_builder("local_a", true).streaming(true).build()],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("local_a"));
    assert_eq!(
        plan.explanation.summary,
        "Selected streaming provider 'local_a' deterministically from 1 eligible candidate(s)."
    );
}

#[test]
fn selects_streaming_provider_and_preserves_deterministic_fallback_order() {
    let providers = || {
        vec![
            cloud_builder("cloud_b").streaming(true).build(),
            local_builder("local_a", true).streaming(true).build(),
            local_builder("local_b", true).streaming(false).build(),
        ]
    };

    let run_plan = plan(default_constraints(), default_preferences(), providers());
    let stream_plan = plan_streaming(default_constraints(), default_preferences(), providers());

    // The mode filters, it never reorders: the streaming candidates keep the
    // relative order they had in the run-mode plan.
    assert_eq!(
        run_plan
            .candidates
            .iter()
            .map(|candidate| candidate.provider_id.as_str())
            .collect::<Vec<_>>(),
        vec!["local_a", "local_b", "cloud_b"]
    );
    assert_eq!(
        stream_plan
            .candidates
            .iter()
            .map(|candidate| candidate.provider_id.as_str())
            .collect::<Vec<_>>(),
        vec!["local_a", "cloud_b"]
    );
    assert_eq!(stream_plan.selected_provider_id.as_deref(), Some("local_a"));
    assert_eq!(
        stream_plan.fallback_provider_ids,
        vec!["cloud_b".to_string()]
    );
    assert_eq!(stream_plan.rejected_providers.len(), 1);
    assert_eq!(stream_plan.rejected_providers[0].provider_id, "local_b");
}

#[test]
fn stream_mode_still_enforces_privacy_and_cloud_constraints() {
    let plan = plan_streaming(
        Constraints {
            privacy: Some(Privacy::LocalRequired),
            cloud: Some(Cloud::Forbidden),
            network_online: Some(true),
        },
        default_preferences(),
        vec![cloud_builder("cloud_a").streaming(true).build()],
    );

    assert_eq!(plan.selected_provider_id, None);
    let codes = plan.rejected_providers[0]
        .reasons
        .iter()
        .map(|reason| reason.code.clone())
        .collect::<Vec<_>>();
    assert!(codes.contains(&Code::PrivacyConstraint));
    assert!(codes.contains(&Code::CloudConstraint));
    assert!(!codes.contains(&Code::StreamingNotSupported));
}

#[test]
fn stream_mode_offline_takes_precedence_over_streaming_mismatch() {
    let plan = plan_streaming(
        Constraints {
            privacy: Some(Privacy::CloudAllowed),
            cloud: Some(Cloud::Allowed),
            network_online: Some(false),
        },
        default_preferences(),
        vec![cloud_builder("cloud_a").streaming(true).build()],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::Offline));
    assert_eq!(plan.rejected_providers[0].reasons[0].code, Code::Offline);
}

#[test]
fn model_profile_rejects_providers_outside_the_profile() {
    let plan = plan_in_profile(
        None,
        default_constraints(),
        default_preferences(),
        &["cloud_a"],
        vec![
            local_provider("local_a", true, true),
            cloud_provider("cloud_a", true),
        ],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("cloud_a"));
    assert!(plan.fallback_provider_ids.is_empty());
    assert_eq!(plan.rejected_providers.len(), 1);
    assert_eq!(plan.rejected_providers[0].provider_id, "local_a");
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        Code::NotInModelProfile
    );
}

#[test]
fn model_profile_order_ranks_ahead_of_preferences() {
    // Balanced preference would put local first; the profile lists cloud first
    // and placement (cloud_allowed) does not separate them.
    let plan = plan_in_profile(
        None,
        default_constraints(),
        default_preferences(),
        &["cloud_a", "local_a"],
        vec![
            local_provider("local_a", true, true),
            cloud_provider("cloud_a", true),
        ],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("cloud_a"));
    assert_eq!(plan.fallback_provider_ids, vec!["local_a".to_string()]);
}

#[test]
fn placement_still_ranks_ahead_of_model_profile_order() {
    let plan = plan_in_profile(
        None,
        Constraints {
            privacy: Some(Privacy::LocalPreferred),
            cloud: Some(Cloud::Allowed),
            network_online: Some(true),
        },
        default_preferences(),
        &["cloud_a", "local_a"],
        vec![
            local_provider("local_a", true, true),
            cloud_provider("cloud_a", true),
        ],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("local_a"));
    assert_eq!(plan.fallback_provider_ids, vec!["cloud_a".to_string()]);
}

#[test]
fn local_required_rejects_a_cloud_provider_listed_in_the_profile() {
    let plan = plan_in_profile(
        None,
        Constraints {
            privacy: Some(Privacy::LocalRequired),
            cloud: Some(Cloud::Allowed),
            network_online: Some(true),
        },
        default_preferences(),
        &["cloud_a"],
        vec![
            local_provider("local_a", true, true),
            cloud_provider("cloud_a", true),
        ],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::CapabilityMismatch));
    let cloud = plan
        .rejected_providers
        .iter()
        .find(|rejected| rejected.provider_id == "cloud_a")
        .expect("cloud_a rejected");
    assert_eq!(cloud.reasons[0].code, Code::PrivacyConstraint);
    let local = plan
        .rejected_providers
        .iter()
        .find(|rejected| rejected.provider_id == "local_a")
        .expect("local_a rejected");
    assert_eq!(local.reasons[0].code, Code::NotInModelProfile);
}

#[test]
fn model_profile_ignores_ids_that_name_no_provider() {
    let plan = plan_in_profile(
        None,
        default_constraints(),
        default_preferences(),
        &["missing", "cloud_a"],
        vec![cloud_provider("cloud_a", true)],
    );

    assert_eq!(plan.selected_provider_id.as_deref(), Some("cloud_a"));
    assert!(plan.rejected_providers.is_empty());
}

#[test]
fn model_profile_stream_chain_is_a_subsequence_of_the_run_chain() {
    let providers = || {
        vec![
            local_builder("local_a", true).build(),
            cloud_builder("cloud_a").streaming(true).build(),
            cloud_builder("cloud_b").streaming(true).build(),
        ]
    };
    let targets = ["cloud_b", "local_a", "cloud_a"];
    let run = plan_in_profile(
        None,
        default_constraints(),
        default_preferences(),
        &targets,
        providers(),
    );
    let stream = plan_in_profile(
        Some(InteractionMode::Stream),
        default_constraints(),
        default_preferences(),
        &targets,
        providers(),
    );

    let run_ids: Vec<_> = run
        .candidates
        .iter()
        .map(|c| c.provider_id.clone())
        .collect();
    let stream_ids: Vec<_> = stream
        .candidates
        .iter()
        .map(|c| c.provider_id.clone())
        .collect();
    assert_eq!(run_ids, vec!["cloud_b", "local_a", "cloud_a"]);
    assert_eq!(stream_ids, vec!["cloud_b", "cloud_a"]);
}

/// The shared cross-SDK vectors (`contracts/fixtures/routing/planner-conformance.json`):
/// each input must plan to exactly the recorded plan, messages included. The SDK
/// suites run the same file through WASM, the Swift FFI and JNI.
#[test]
fn matches_the_shared_planner_conformance_vectors() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/fixtures/routing/planner-conformance.json"
    ))
    .expect("conformance fixture parses");
    let cases = fixture["cases"].as_array().expect("cases array");
    assert!(!cases.is_empty());

    for case in cases {
        let id = case["id"].as_str().expect("case id");
        let input: RoutePlannerInput = serde_json::from_value(case["input"].clone())
            .unwrap_or_else(|error| {
                panic!("case '{id}': input does not parse: {error}");
            });
        let plan = serde_json::to_value(plan_route(input)).expect("plan serializes");
        assert_eq!(plan, case["expected"], "case '{id}'");
    }
}

/// The comparison above parses both sides with the same `serde_json`, so a lossy
/// float parse would round input and expectation alike and still pass. Pin the
/// exact bits of the `controls_float_round_trip` value through the JSON text the
/// FFI entry points read and write: without `float_roundtrip` the planner hands
/// back 1.14 and every engine's exact plan check refuses the run.
#[test]
fn control_values_round_trip_through_the_planner_bit_for_bit() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/fixtures/routing/planner-conformance.json"
    ))
    .expect("conformance fixture parses");
    let case = fixture["cases"]
        .as_array()
        .expect("cases array")
        .iter()
        .find(|case| case["id"] == "controls_float_round_trip")
        .expect("controls_float_round_trip case");
    let input_json = serde_json::to_string(&case["input"]).expect("input serializes");
    assert!(input_json.contains("1.1400000000000001"));

    let input: RoutePlannerInput = serde_json::from_str(&input_json).expect("input parses");
    let requested = input.task.controls.as_ref().expect("controls")[0].value;
    assert_eq!(requested.to_bits(), 1.140_000_000_000_000_1_f64.to_bits());

    let plan_json = serde_json::to_string(&plan_route(input)).expect("plan serializes");
    assert!(
        plan_json.contains("\"value\":1.1400000000000001"),
        "plan rounded the control value: {plan_json}"
    );
}

// Speech-control negotiation (ADR 025): the effective-state merge and the
// rejection reasons, below the planner. The conformance vectors cover the
// planner wiring end to end.

fn control_declaration(
    id: SpeechControlId,
    deliveries: &[ControlDelivery],
    lifetime: SpeechControlLifetime,
) -> SpeechControlDeclaration {
    let phase = if id == SpeechControlId::PlaybackVolume {
        SpeechControlPhase::Playback
    } else {
        SpeechControlPhase::Synthesis
    };
    SpeechControlDeclaration {
        deliveries: deliveries.to_vec(),
        id,
        lifetime,
        phase,
        value_kind: SpeechControlValueKind::Number,
    }
}

fn rate_declaration(deliveries: &[ControlDelivery]) -> SpeechControlDeclaration {
    control_declaration(
        SpeechControlId::SpeechSpeakingRate,
        deliveries,
        SpeechControlLifetime::Utterance,
    )
}

fn rate_state(
    delivery: ControlDelivery,
    available: Option<bool>,
    range: Option<(f64, f64)>,
) -> SpeechControlState {
    SpeechControlState {
        available,
        delivery,
        id: SpeechControlId::SpeechSpeakingRate,
        range: range.map(|(min, max)| SpeechControlRange {
            speech_control_range_default: None,
            max,
            min,
            step: None,
        }),
        reason: None,
    }
}

fn voice_with_states(id: &str, states: Vec<SpeechControlState>) -> ProviderVoice {
    ProviderVoice {
        control_states: Some(states),
        gender: None,
        id: Some(id.to_string()),
        locale: "de-DE".to_string(),
        locales: None,
        name: None,
        network_required: None,
        readiness: None,
    }
}

fn rate_support(
    declarations: &[SpeechControlDeclaration],
    states: &[SpeechControlState],
    voice: Option<&ProviderVoice>,
    delivery: ControlDelivery,
) -> ControlSupport {
    control_support(
        ControlCapability {
            declarations,
            states,
        },
        voice,
        &SpeechControlId::SpeechSpeakingRate,
        &delivery,
    )
}

const PLAYBACK: ControlDelivery = ControlDelivery::Playback;
const ARTIFACT: ControlDelivery = ControlDelivery::Artifact;

#[test]
fn control_support_reads_the_task_state_without_a_voice() {
    let declarations = [rate_declaration(&[PLAYBACK])];
    let states = [rate_state(PLAYBACK, Some(true), Some((0.5, 2.0)))];
    let support = rate_support(&declarations, &states, None, PLAYBACK);
    assert_eq!(support, ControlSupport::Supported { min: 0.5, max: 2.0 });
    assert!(
        support.admits(0.5) && support.admits(2.0),
        "range is inclusive"
    );
    assert!(!support.admits(2.01) && !support.admits(0.49));
}

#[test]
fn control_support_overlays_the_voice_field_by_field() {
    let declarations = [rate_declaration(&[PLAYBACK])];
    let states = [rate_state(PLAYBACK, Some(true), Some((0.5, 2.0)))];

    // A voice range alone replaces the task range and inherits availability.
    let narrower = voice_with_states("narrow", vec![rate_state(PLAYBACK, None, Some((0.8, 1.2)))]);
    assert_eq!(
        rate_support(&declarations, &states, Some(&narrower), PLAYBACK),
        ControlSupport::Supported { min: 0.8, max: 1.2 }
    );

    // An explicit available: false disables the control for that voice.
    let disabled = voice_with_states("off", vec![rate_state(PLAYBACK, Some(false), None)]);
    assert_eq!(
        rate_support(&declarations, &states, Some(&disabled), PLAYBACK),
        ControlSupport::Unsupported
    );

    // A voice without an entry for the pair inherits the task state.
    let silent = voice_with_states("silent", Vec::new());
    assert_eq!(
        rate_support(&declarations, &states, Some(&silent), PLAYBACK),
        ControlSupport::Supported { min: 0.5, max: 2.0 }
    );

    // A voice can supply what the task leaves unknown.
    let task_unknown = [rate_state(PLAYBACK, None, None)];
    let knows = voice_with_states(
        "knows",
        vec![rate_state(PLAYBACK, Some(true), Some((0.5, 1.5)))],
    );
    assert_eq!(
        rate_support(&declarations, &task_unknown, Some(&knows), PLAYBACK),
        ControlSupport::Supported { min: 0.5, max: 1.5 }
    );
}

#[test]
fn control_support_never_inherits_across_deliveries() {
    let declarations = [rate_declaration(&[PLAYBACK, ARTIFACT])];
    let states = [rate_state(PLAYBACK, Some(true), Some((0.5, 2.0)))];
    let voice = voice_with_states(
        "v",
        vec![rate_state(PLAYBACK, Some(true), Some((0.5, 3.0)))],
    );
    assert_eq!(
        rate_support(&declarations, &states, Some(&voice), ARTIFACT),
        ControlSupport::AvailabilityUnknown
    );
}

#[test]
fn control_support_treats_unknown_as_unsupported_for_application() {
    let declarations = [rate_declaration(&[PLAYBACK])];

    let unknown = rate_support(&declarations, &[], None, PLAYBACK);
    assert_eq!(unknown, ControlSupport::AvailabilityUnknown);
    assert!(!unknown.admits(1.0));
    assert_eq!(
        unknown.omission(1.0),
        Some(ControlOmissionReason::AvailabilityUnknown)
    );

    let no_range = [rate_state(PLAYBACK, Some(true), None)];
    let range_unknown = rate_support(&declarations, &no_range, None, PLAYBACK);
    assert_eq!(range_unknown, ControlSupport::RangeUnknown);
    assert_eq!(
        range_unknown.omission(1.0),
        Some(ControlOmissionReason::RangeUnknown)
    );

    let supported = ControlSupport::Supported { min: 0.5, max: 2.0 };
    assert_eq!(supported.omission(1.0), None);
    assert_eq!(
        supported.omission(3.0),
        Some(ControlOmissionReason::OutOfRange)
    );
    assert_eq!(
        ControlSupport::Unsupported.omission(1.0),
        Some(ControlOmissionReason::Unsupported)
    );
}

#[test]
fn control_support_requires_one_utterance_declaration_for_the_delivery() {
    let states = [
        rate_state(PLAYBACK, Some(true), Some((0.5, 2.0))),
        rate_state(ARTIFACT, Some(true), Some((0.5, 2.0))),
    ];

    // Not declared at all.
    assert_eq!(
        rate_support(&[], &states, None, PLAYBACK),
        ControlSupport::Unsupported
    );
    // Declared, but not for this delivery: its state is ignored.
    assert_eq!(
        rate_support(&[rate_declaration(&[PLAYBACK])], &states, None, ARTIFACT),
        ControlSupport::Unsupported
    );
    // A provider-instance setting never satisfies a request.
    let instance = control_declaration(
        SpeechControlId::SpeechSpeakingRate,
        &[PLAYBACK],
        SpeechControlLifetime::ProviderInstance,
    );
    assert_eq!(
        rate_support(&[instance], &states, None, PLAYBACK),
        ControlSupport::Unsupported
    );
    // Declared twice, even identically.
    let twice = [rate_declaration(&[PLAYBACK]), rate_declaration(&[PLAYBACK])];
    assert_eq!(
        rate_support(&twice, &states, None, PLAYBACK),
        ControlSupport::Unsupported
    );
}

#[test]
fn control_support_refuses_a_declaration_that_breaks_its_id_invariant() {
    let declared = |id: SpeechControlId,
                    value_kind: SpeechControlValueKind,
                    phase: SpeechControlPhase,
                    deliveries: &[ControlDelivery]| SpeechControlDeclaration {
        deliveries: deliveries.to_vec(),
        id,
        lifetime: SpeechControlLifetime::Utterance,
        phase,
        value_kind,
    };
    let support = |declaration: SpeechControlDeclaration, delivery: ControlDelivery| {
        let id = declaration.id.clone();
        let states = [SpeechControlState {
            id: id.clone(),
            ..rate_state(delivery.clone(), Some(true), Some((0.0, 2.0)))
        }];
        control_support(
            ControlCapability {
                declarations: &[declaration],
                states: &states,
            },
            None,
            &id,
            &delivery,
        )
    };
    let supported = ControlSupport::Supported { min: 0.0, max: 2.0 };
    use SpeechControlId::*;
    use SpeechControlPhase::{Playback as PlaybackPhase, Synthesis};
    use SpeechControlValueKind::{Boolean, Choice, Number};

    // The shapes the schema allows.
    for (id, phase) in [
        (SpeechSpeakingRate, Synthesis),
        (SpeechPitch, Synthesis),
        (PlaybackVolume, PlaybackPhase),
    ] {
        let declaration = declared(id, Number, phase, &[PLAYBACK]);
        assert!(declaration_keeps_invariant(&declaration));
        assert_eq!(support(declaration, PLAYBACK), supported);
    }
    let rate_both = declared(SpeechSpeakingRate, Number, Synthesis, &[PLAYBACK, ARTIFACT]);
    assert!(declaration_keeps_invariant(&rate_both));
    assert_eq!(support(rate_both, ARTIFACT), supported);

    // Representable through serde, refused for every delivery it lists.
    for (declaration, delivery) in [
        (
            declared(SpeechSpeakingRate, Choice, Synthesis, &[PLAYBACK]),
            PLAYBACK,
        ),
        (
            declared(SpeechPitch, Boolean, Synthesis, &[PLAYBACK]),
            PLAYBACK,
        ),
        (
            declared(SpeechSpeakingRate, Number, PlaybackPhase, &[PLAYBACK]),
            PLAYBACK,
        ),
        (
            declared(SpeechPitch, Number, PlaybackPhase, &[PLAYBACK]),
            PLAYBACK,
        ),
        (
            declared(PlaybackVolume, Number, Synthesis, &[PLAYBACK]),
            PLAYBACK,
        ),
        (
            declared(PlaybackVolume, Choice, PlaybackPhase, &[PLAYBACK]),
            PLAYBACK,
        ),
        (
            declared(PlaybackVolume, Number, PlaybackPhase, &[PLAYBACK, ARTIFACT]),
            PLAYBACK,
        ),
        (
            declared(PlaybackVolume, Number, PlaybackPhase, &[PLAYBACK, ARTIFACT]),
            ARTIFACT,
        ),
        (
            declared(PlaybackVolume, Number, PlaybackPhase, &[ARTIFACT]),
            ARTIFACT,
        ),
    ] {
        assert!(
            !declaration_keeps_invariant(&declaration),
            "{declaration:?} breaks its invariant"
        );
        assert_eq!(support(declaration, delivery), ControlSupport::Unsupported);
    }
}

#[test]
fn control_support_refuses_duplicate_states_at_either_level() {
    let declarations = [rate_declaration(&[PLAYBACK, ARTIFACT])];
    let state = || rate_state(PLAYBACK, Some(true), Some((0.5, 2.0)));

    assert_eq!(
        rate_support(&declarations, &[state(), state()], None, PLAYBACK),
        ControlSupport::Unsupported
    );
    let voice = voice_with_states("v", vec![state(), state()]);
    assert_eq!(
        rate_support(&declarations, &[state()], Some(&voice), PLAYBACK),
        ControlSupport::Unsupported
    );
    // A duplicate for one delivery leaves the other delivery alone.
    let artifact = [
        state(),
        state(),
        rate_state(ARTIFACT, Some(true), Some((0.8, 1.2))),
    ];
    assert_eq!(
        rate_support(&declarations, &artifact, None, ARTIFACT),
        ControlSupport::Supported { min: 0.8, max: 1.2 }
    );
}

fn speech_input(
    mode: Option<OutputDelivery>,
    interaction_mode: Option<InteractionMode>,
    controls: Option<Vec<ControlRequirement>>,
) -> RoutePlannerInput {
    RoutePlannerInput {
        constraints: default_constraints(),
        interaction_mode,
        model_profile: None,
        preferences: default_preferences(),
        providers: Vec::new(),
        task: Task {
            controls,
            delivery: mode.map(|mode| DeliveryRequirement {
                media_types: None,
                mode,
            }),
            inputs: Some(vec![TaskInputKind::Text]),
            kind: "text_to_speech".to_string(),
            locale: None,
            voice: None,
        },
    }
}

fn rate_request(value: f64, requirement: RequirementLevel) -> ControlRequirement {
    ControlRequirement {
        id: SpeechControlId::SpeechSpeakingRate,
        requirement,
        value,
    }
}

fn pitch_request(value: f64, requirement: RequirementLevel) -> ControlRequirement {
    ControlRequirement {
        id: SpeechControlId::SpeechPitch,
        requirement,
        value,
    }
}

#[test]
fn requested_controls_ignores_requests_with_nothing_to_negotiate() {
    let controls = || Some(vec![rate_request(1.2, RequirementLevel::Required)]);
    let playback = Some(OutputDelivery::Playback);

    assert!(requested_controls(&speech_input(playback.clone(), None, controls())).is_some());
    assert!(requested_controls(&speech_input(playback.clone(), None, None)).is_none());
    assert!(requested_controls(&speech_input(playback.clone(), None, Some(Vec::new()))).is_none());
    assert!(
        requested_controls(&speech_input(
            playback,
            Some(InteractionMode::Prepare),
            controls()
        ))
        .is_none()
    );
    assert!(
        requested_controls(&speech_input(
            Some(OutputDelivery::Inline),
            None,
            controls()
        ))
        .is_none()
    );
    assert!(requested_controls(&speech_input(None, None, controls())).is_none());
}

fn rate_and_pitch_capability() -> (Vec<SpeechControlDeclaration>, Vec<SpeechControlState>) {
    let pitch = |range| SpeechControlState {
        available: Some(true),
        delivery: PLAYBACK,
        id: SpeechControlId::SpeechPitch,
        range: Some(SpeechControlRange {
            speech_control_range_default: None,
            max: range,
            min: 0.5,
            step: None,
        }),
        reason: None,
    };
    (
        vec![
            rate_declaration(&[PLAYBACK]),
            control_declaration(
                SpeechControlId::SpeechPitch,
                &[PLAYBACK],
                SpeechControlLifetime::Utterance,
            ),
        ],
        vec![
            rate_state(PLAYBACK, Some(true), Some((0.5, 2.0))),
            pitch(2.0),
        ],
    )
}

fn pitch_disabled() -> SpeechControlState {
    SpeechControlState {
        available: Some(false),
        delivery: PLAYBACK,
        id: SpeechControlId::SpeechPitch,
        range: None,
        reason: None,
    }
}

fn reason_codes(reasons: &[Reason]) -> Vec<Code> {
    reasons.iter().map(|reason| reason.code.clone()).collect()
}

#[test]
fn rejection_reasons_pick_out_of_range_only_when_some_voice_supports_the_control() {
    let (declarations, states) = rate_and_pitch_capability();
    let capability = ControlCapability {
        declarations: &declarations,
        states: &states,
    };
    let input = speech_input(
        Some(OutputDelivery::Playback),
        None,
        Some(vec![
            rate_request(3.0, RequirementLevel::Required),
            pitch_request(1.1, RequirementLevel::Required),
        ]),
    );
    let requested = requested_controls(&input).expect("controls requested");

    // One voice supports rate with another range, the other disables it.
    let narrow = voice_with_states("narrow", Vec::new());
    let off = voice_with_states("off", vec![rate_state(PLAYBACK, Some(false), None)]);
    let reasons = requested.rejection_reasons("p", capability, Some(&[&narrow, &off]));
    assert_eq!(reason_codes(&reasons), vec![Code::SpeechControlOutOfRange]);
    assert_eq!(
        reasons[0].message,
        "Provider 'p': speech.speakingRate 3 is outside every voice's range for playback."
    );

    // Only the disabled voice is bindable: unsupported.
    let reasons = requested.rejection_reasons("p", capability, Some(&[&off]));
    assert_eq!(reason_codes(&reasons), vec![Code::SpeechControlUnsupported]);
    assert_eq!(
        reasons[0].message,
        "Provider 'p': no voice supports required speech.speakingRate for playback."
    );

    // Without a voice list the task state decides, with its own wording.
    let reasons = requested.rejection_reasons("p", capability, None);
    assert_eq!(reason_codes(&reasons), vec![Code::SpeechControlOutOfRange]);
    assert_eq!(
        reasons[0].message,
        "Provider 'p': speech.speakingRate 3 is outside the supported range for playback."
    );
}

#[test]
fn rejection_reasons_report_each_failing_control_in_request_order() {
    let declarations = vec![];
    let capability = ControlCapability {
        declarations: &declarations,
        states: &[],
    };
    let input = speech_input(
        Some(OutputDelivery::Playback),
        None,
        Some(vec![
            rate_request(1.2, RequirementLevel::Required),
            pitch_request(1.1, RequirementLevel::Preferred),
        ]),
    );
    let requested = requested_controls(&input).expect("controls requested");
    let voice = voice_with_states("v", Vec::new());

    // A preferred control never produces a reason.
    let reasons = requested.rejection_reasons("p", capability, Some(&[&voice]));
    assert_eq!(reason_codes(&reasons), vec![Code::SpeechControlUnsupported]);
    let reasons = requested.rejection_reasons("p", capability, None);
    assert_eq!(
        reasons[0].message,
        "Provider 'p': required speech.speakingRate is not supported for playback."
    );
    // No bindable voice at all: nothing supports the control.
    let reasons = requested.rejection_reasons("p", capability, Some(&[]));
    assert_eq!(reason_codes(&reasons), vec![Code::SpeechControlUnsupported]);
}

#[test]
fn rejection_reasons_name_the_combination_when_each_control_is_met_alone() {
    let (declarations, states) = rate_and_pitch_capability();
    let capability = ControlCapability {
        declarations: &declarations,
        states: &states,
    };
    let input = speech_input(
        Some(OutputDelivery::Playback),
        None,
        Some(vec![
            rate_request(1.2, RequirementLevel::Required),
            pitch_request(1.1, RequirementLevel::Required),
        ]),
    );
    let requested = requested_controls(&input).expect("controls requested");
    let rate_only = voice_with_states("rate-only", vec![pitch_disabled()]);
    let pitch_only = voice_with_states("pitch-only", vec![rate_state(PLAYBACK, Some(false), None)]);

    let reasons = requested.rejection_reasons("p", capability, Some(&[&rate_only, &pitch_only]));
    assert_eq!(reason_codes(&reasons), vec![Code::SpeechControlUnsupported]);
    assert_eq!(
        reasons[0].message,
        "Provider 'p': no single voice supports every required speech control for playback."
    );

    // One voice that meets both clears the provider.
    let both = voice_with_states("both", Vec::new());
    assert!(
        requested
            .rejection_reasons("p", capability, Some(&[&rate_only, &pitch_only, &both]))
            .is_empty()
    );
}

/// A speech provider with one voice and a supported rate, for planner-level
/// control checks.
fn rate_speech_provider() -> Provider {
    let mut provider = local_builder("speech_local", true).build();
    provider.descriptor.tasks = vec!["text_to_speech".to_string()];
    provider.descriptor.task_capabilities = Some(vec![ProviderTaskCapability {
        cancel: CancelSemantics::Hard,
        controls: Some(vec![rate_declaration(&[PLAYBACK])]),
        inputs: vec![TaskInputKind::Text],
        interaction: ProviderTaskInteraction {
            prepare: Some(true),
            run: true,
            stream: false,
        },
        kind: "text_to_speech".to_string(),
        locales: None,
        outputs: vec![ProviderTaskOutput {
            delivery: OutputDelivery::Playback,
            media_types: None,
        }],
        privacy: None,
    }]);
    provider.capabilities.task_capabilities = Some(vec![ProviderTaskAvailability {
        available: None,
        cancellation_available: None,
        control_states: Some(vec![rate_state(PLAYBACK, Some(true), Some((0.5, 2.0)))]),
        kind: "text_to_speech".to_string(),
        locales: None,
        readiness: None,
        reason: None,
        streaming_available: None,
        streaming_unavailable_reason: None,
        voices: Some(vec![voice_with_states("v", Vec::new())]),
    }]);
    provider
}

#[test]
fn planner_binds_a_control_plan_only_when_there_is_something_to_negotiate() {
    let controls = || Some(vec![rate_request(1.2, RequirementLevel::Required)]);
    let plan_for = |mode, interaction_mode, controls| {
        let mut input = speech_input(mode, interaction_mode, controls);
        input.providers = vec![rate_speech_provider()];
        plan_route(input)
    };

    let negotiated = plan_for(Some(OutputDelivery::Playback), None, controls());
    let candidate = &negotiated.candidates[0];
    assert_eq!(
        candidate.controls,
        Some(vec![ControlApplicationPlan {
            decision: ControlDecision::Apply,
            id: SpeechControlId::SpeechSpeakingRate,
            reason: None,
            requirement: RequirementLevel::Required,
            value: 1.2,
        }])
    );
    assert_eq!(
        candidate
            .voice
            .as_ref()
            .and_then(|voice| voice.id.as_deref()),
        Some("v")
    );

    // Without controls nothing is bound, as before controls existed.
    let plain = plan_for(Some(OutputDelivery::Playback), None, None);
    assert_eq!(plain.candidates[0].controls, None);
    assert_eq!(plain.candidates[0].voice, None);

    // Prepare carries no controls; the plan binds none.
    let prepare = plan_for(
        Some(OutputDelivery::Playback),
        Some(InteractionMode::Prepare),
        controls(),
    );
    assert_eq!(
        prepare.selected_provider_id.as_deref(),
        Some("speech_local")
    );
    assert_eq!(prepare.candidates[0].controls, None);
}

#[test]
fn rejection_reasons_never_reject_for_preferred_controls_alone() {
    let (declarations, states) = rate_and_pitch_capability();
    let capability = ControlCapability {
        declarations: &declarations,
        states: &states,
    };
    let input = speech_input(
        Some(OutputDelivery::Playback),
        None,
        Some(vec![
            rate_request(3.0, RequirementLevel::Preferred),
            pitch_request(1.1, RequirementLevel::Preferred),
        ]),
    );
    let requested = requested_controls(&input).expect("controls requested");
    let off = voice_with_states("off", vec![rate_state(PLAYBACK, Some(false), None)]);

    assert!(
        requested
            .rejection_reasons("p", capability, Some(&[]))
            .is_empty()
    );
    assert!(
        requested
            .rejection_reasons("p", capability, Some(&[&off]))
            .is_empty()
    );
    assert!(
        requested
            .rejection_reasons("p", capability, None)
            .is_empty()
    );
}
