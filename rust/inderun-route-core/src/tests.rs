use crate::*;

fn local_provider(id: &str, available: bool, private: bool) -> ProviderInput {
    ProviderInput {
        descriptor: ProviderDescriptor {
            id: id.to_string(),
            provider_type: ProviderType::Local,
            supports: ProviderRunSupport { run: true },
            tasks: vec!["text_to_text".to_string()],
            privacy: Some(ProviderPrivacy {
                data_leaves_device: !private,
                regions: None,
            }),
        },
        capabilities: ProviderCapabilitySnapshot {
            available,
            reason: (!available).then(|| "Local runtime unavailable.".to_string()),
        },
    }
}

fn cloud_provider(id: &str, available: bool) -> ProviderInput {
    ProviderInput {
        descriptor: ProviderDescriptor {
            id: id.to_string(),
            provider_type: ProviderType::Cloud,
            supports: ProviderRunSupport { run: true },
            tasks: vec!["text_to_text".to_string()],
            privacy: Some(ProviderPrivacy {
                data_leaves_device: true,
                regions: None,
            }),
        },
        capabilities: ProviderCapabilitySnapshot {
            available,
            reason: (!available).then(|| "Cloud runtime unavailable.".to_string()),
        },
    }
}

fn plan(
    constraints: RoutingConstraints,
    preferences: RoutingPreferences,
    providers: Vec<ProviderInput>,
) -> RoutePlan {
    plan_route(PlanRouteInput {
        task: RoutingTask {
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
        RoutingConstraints {
            privacy: Some(PrivacyConstraint::LocalPreferred),
            cloud: Some(CloudConstraint::Allowed),
            network_online: Some(true),
        },
        RoutingPreferences {
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
        RoutingConstraints {
            privacy: None,
            cloud: Some(CloudConstraint::Forbidden),
            network_online: Some(true),
        },
        RoutingPreferences::default(),
        vec![cloud_provider("cloud_a", true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(
        plan.failure_code,
        Some(RouteFailureCode::CapabilityMismatch)
    );
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        RejectionReasonCode::CloudConstraint
    );
}

#[test]
fn rejects_local_providers_when_cloud_is_required() {
    let plan = plan(
        RoutingConstraints {
            privacy: Some(PrivacyConstraint::CloudRequired),
            cloud: Some(CloudConstraint::Required),
            network_online: Some(true),
        },
        RoutingPreferences::default(),
        vec![local_provider("local_a", true, true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(RouteFailureCode::Unavailable));
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        RejectionReasonCode::PrivacyConstraint
    );
}

#[test]
fn returns_offline_failure_for_cloud_when_host_is_offline() {
    let plan = plan(
        RoutingConstraints {
            privacy: None,
            cloud: Some(CloudConstraint::Allowed),
            network_online: Some(false),
        },
        RoutingPreferences::default(),
        vec![cloud_provider("cloud_a", true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(plan.failure_code, Some(RouteFailureCode::Offline));
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        RejectionReasonCode::Offline
    );
}

#[test]
fn preserves_deterministic_fallback_order() {
    let plan = plan(
        RoutingConstraints {
            privacy: Some(PrivacyConstraint::CloudAllowed),
            cloud: Some(CloudConstraint::Allowed),
            network_online: Some(true),
        },
        RoutingPreferences {
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
        RoutingConstraints {
            privacy: Some(PrivacyConstraint::LocalRequired),
            cloud: Some(CloudConstraint::Allowed),
            network_online: Some(true),
        },
        RoutingPreferences::default(),
        vec![local_provider("local_a", false, true)],
    );

    assert_eq!(plan.selected_provider_id, None);
    assert_eq!(
        plan.failure_code,
        Some(RouteFailureCode::CapabilityMismatch)
    );
    assert_eq!(
        plan.rejected_providers[0].reasons[0].code,
        RejectionReasonCode::CapabilityUnavailable
    );
}
