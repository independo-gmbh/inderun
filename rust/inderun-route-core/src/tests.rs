use crate::*;

fn local_provider(id: &str, available: bool, private: bool) -> Provider {
    Provider {
        descriptor: Descriptor {
            id: id.to_string(),
            descriptor_type: Type::Local,
            supports: Supports { run: true },
            tasks: vec!["text_to_text".to_string()],
            privacy: Some(PrivacyClass {
                data_leaves_device: !private,
                regions: None,
            }),
        },
        capabilities: Capabilities {
            available,
            reason: (!available).then(|| "Local runtime unavailable.".to_string()),
        },
    }
}

fn cloud_provider(id: &str, available: bool) -> Provider {
    Provider {
        descriptor: Descriptor {
            id: id.to_string(),
            descriptor_type: Type::Cloud,
            supports: Supports { run: true },
            tasks: vec!["text_to_text".to_string()],
            privacy: Some(PrivacyClass {
                data_leaves_device: true,
                regions: None,
            }),
        },
        capabilities: Capabilities {
            available,
            reason: (!available).then(|| "Cloud runtime unavailable.".to_string()),
        },
    }
}

fn plan(constraints: Constraints, preferences: Preferences, providers: Vec<Provider>) -> RoutePlan {
    plan_route(RoutePlannerInput {
        task: Task {
            kind: "text_to_text".to_string(),
        },
        constraints,
        preferences,
        providers,
    })
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
