use crate::*;

/// Test provider builder. Defaults mirror a shipped Mode-1 provider: `run: true`,
/// no streaming declared, no dynamic streaming/cancellation overrides.
struct ProviderBuilder {
    provider: Provider,
    unavailable_reason: String,
}

impl ProviderBuilder {
    fn new(id: &str, descriptor_type: Type, data_leaves_device: bool) -> Self {
        let unavailable_reason = match descriptor_type {
            Type::Cloud => "Cloud runtime unavailable.",
            _ => "Local runtime unavailable.",
        };
        Self {
            provider: Provider {
                descriptor: Descriptor {
                    id: id.to_string(),
                    descriptor_type,
                    supports: Supports {
                        run: true,
                        streaming: None,
                    },
                    cancel: None,
                    tasks: vec!["text_to_text".to_string()],
                    privacy: Some(PrivacyClass {
                        data_leaves_device,
                        regions: None,
                    }),
                },
                capabilities: Capabilities {
                    available: true,
                    reason: None,
                    streaming_available: None,
                    streaming_unavailable_reason: None,
                    cancellation_available: None,
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

    fn streaming(mut self, streaming: Option<bool>) -> Self {
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

fn local_builder(id: &str, private: bool) -> ProviderBuilder {
    ProviderBuilder::new(id, Type::Local, !private)
}

fn cloud_builder(id: &str) -> ProviderBuilder {
    ProviderBuilder::new(id, Type::Cloud, true)
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
        task: Task {
            kind: "text_to_text".to_string(),
        },
        interaction_mode,
        constraints,
        preferences,
        providers,
    })
}

fn default_constraints() -> Constraints {
    Constraints {
        privacy: Some(PrivacyEnum::CloudAllowed),
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
            privacy: Some(PrivacyEnum::LocalPreferred),
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
            privacy: Some(PrivacyEnum::CloudRequired),
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
            privacy: Some(PrivacyEnum::CloudAllowed),
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
            privacy: Some(PrivacyEnum::LocalRequired),
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
                .streaming(Some(false))
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
    // Wire-level back-compat: a planner input produced before `interactionMode`,
    // `supports.streaming`, and the dynamic streaming fields existed must still
    // deserialize and plan exactly as it did before.
    let legacy = r#"{
        "task": { "kind": "text_to_text" },
        "constraints": { "privacy": "cloud_allowed", "cloud": "allowed", "networkOnline": true },
        "preferences": { "optimizeFor": "balanced" },
        "providers": [
            {
                "descriptor": {
                    "id": "local_a",
                    "type": "local",
                    "supports": { "run": true },
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
        vec![
            local_builder("local_a", true)
                .streaming(Some(false))
                .build(),
        ],
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
fn absent_streaming_flag_is_treated_as_not_streaming() {
    let plan = plan_streaming(
        default_constraints(),
        default_preferences(),
        vec![local_builder("local_a", true).streaming(None).build()],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        Code::StreamingNotSupported
    );
}

#[test]
fn rejects_providers_whose_dynamic_streaming_is_disabled() {
    let plan = plan_streaming(
        default_constraints(),
        default_preferences(),
        vec![
            local_builder("local_a", true)
                .streaming(Some(true))
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
        vec![local_builder("local_a", true).streaming(Some(true)).build()],
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
            cloud_builder("cloud_b").streaming(Some(true)).build(),
            local_builder("local_a", true).streaming(Some(true)).build(),
            local_builder("local_b", true)
                .streaming(Some(false))
                .build(),
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
            privacy: Some(PrivacyEnum::LocalRequired),
            cloud: Some(Cloud::Forbidden),
            network_online: Some(true),
        },
        default_preferences(),
        vec![cloud_builder("cloud_a").streaming(Some(true)).build()],
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
            privacy: Some(PrivacyEnum::CloudAllowed),
            cloud: Some(Cloud::Allowed),
            network_online: Some(false),
        },
        default_preferences(),
        vec![cloud_builder("cloud_a").streaming(Some(true)).build()],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(FailureCode::Offline));
    assert_eq!(plan.rejected_providers[0].reasons[0].code, Code::Offline);
}
