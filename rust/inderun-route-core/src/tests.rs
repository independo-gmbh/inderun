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
