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
