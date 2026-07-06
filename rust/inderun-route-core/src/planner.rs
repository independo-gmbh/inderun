//! Deterministic route-planning algorithm.
//!
//! [`plan_route`] sorts the candidate providers by placement and preference
//! rank, filters out any that violate the request constraints, and produces a
//! [`RoutePlan`] with a stable selection plus an inspectable explanation.

use std::cmp::Ordering;

use crate::model::*;

pub fn plan_route(input: PlanRouteInput) -> RoutePlan {
    let mut providers = input.providers.clone();
    providers
        .sort_by(|left, right| compare_inputs(left, right, &input.preferences, &input.constraints));

    let mut candidates = Vec::new();
    let mut rejected_providers = Vec::new();

    for provider in &providers {
        let reasons = evaluate_provider(provider, &input);
        if reasons.is_empty() {
            candidates.push(RouteCandidate {
                provider_id: provider.descriptor.id.clone(),
                order: candidates.len(),
            });
        } else {
            rejected_providers.push(RejectedProvider {
                provider_id: provider.descriptor.id.clone(),
                reasons,
            });
        }
    }

    if let Some(selected) = candidates.first() {
        let selected_provider_id = selected.provider_id.clone();
        let candidate_count = candidates.len();
        let fallback_provider_ids = candidates
            .iter()
            .skip(1)
            .map(|candidate| candidate.provider_id.clone())
            .collect::<Vec<_>>();

        return RoutePlan {
            selected_provider_id: Some(selected_provider_id.clone()),
            fallback_provider_ids,
            candidates,
            rejected_providers,
            failure_code: None,
            explanation: RouteExplanation {
                summary: format!(
                    "Selected provider '{}' deterministically from {} eligible candidate(s).",
                    selected_provider_id, candidate_count
                ),
                selected_provider_id: Some(selected_provider_id),
            },
        };
    }

    let failure_code = infer_failure_code(&input.constraints, &rejected_providers);
    let summary = match failure_code {
        RouteFailureCode::CapabilityMismatch => format!(
            "No eligible local provider found for task '{}'.",
            input.task.kind
        ),
        RouteFailureCode::Offline => {
            "Cloud execution was blocked because the host is offline.".to_string()
        }
        RouteFailureCode::Unavailable => {
            format!(
                "No eligible cloud provider found for task '{}'.",
                input.task.kind
            )
        }
    };

    RoutePlan {
        selected_provider_id: None,
        fallback_provider_ids: Vec::new(),
        candidates,
        rejected_providers,
        failure_code: Some(failure_code),
        explanation: RouteExplanation {
            summary,
            selected_provider_id: None,
        },
    }
}

fn compare_inputs(
    left: &ProviderInput,
    right: &ProviderInput,
    preferences: &RoutingPreferences,
    constraints: &RoutingConstraints,
) -> Ordering {
    priority_tuple(left, preferences, constraints)
        .cmp(&priority_tuple(right, preferences, constraints))
        .then_with(|| left.descriptor.id.cmp(&right.descriptor.id))
}

fn priority_tuple(
    provider: &ProviderInput,
    preferences: &RoutingPreferences,
    constraints: &RoutingConstraints,
) -> (u8, u8, String) {
    let placement_rank = placement_rank(provider, constraints);
    let preference_rank = preference_rank(provider, preferences);
    (
        placement_rank,
        preference_rank,
        provider.descriptor.id.clone(),
    )
}

fn placement_rank(provider: &ProviderInput, constraints: &RoutingConstraints) -> u8 {
    let descriptor = &provider.descriptor;

    match constraints.cloud {
        Some(CloudConstraint::Required) => {
            if descriptor.provider_type == ProviderType::Cloud {
                0
            } else {
                1
            }
        }
        Some(CloudConstraint::Forbidden) => {
            if descriptor.provider_type == ProviderType::Cloud {
                1
            } else {
                0
            }
        }
        Some(CloudConstraint::Allowed) | None => match constraints.privacy {
            Some(PrivacyConstraint::LocalRequired) | Some(PrivacyConstraint::LocalPreferred) => {
                if is_data_private(descriptor) {
                    0
                } else {
                    1
                }
            }
            Some(PrivacyConstraint::CloudRequired) => {
                if descriptor.provider_type == ProviderType::Cloud {
                    0
                } else {
                    1
                }
            }
            Some(PrivacyConstraint::CloudAllowed) | None => 0,
        },
    }
}

fn preference_rank(provider: &ProviderInput, preferences: &RoutingPreferences) -> u8 {
    match preferences.optimize_for {
        Some(OptimizeFor::Privacy) => {
            if is_data_private(&provider.descriptor) {
                0
            } else {
                1
            }
        }
        Some(OptimizeFor::Latency) => match provider.descriptor.provider_type {
            ProviderType::Cloud => 0,
            ProviderType::Edge => 1,
            ProviderType::Local => 2,
        },
        Some(OptimizeFor::Cost) | Some(OptimizeFor::Balanced) | None => {
            match provider.descriptor.provider_type {
                ProviderType::Local => 0,
                ProviderType::Edge => 1,
                ProviderType::Cloud => 2,
            }
        }
    }
}

fn is_data_private(descriptor: &ProviderDescriptor) -> bool {
    descriptor
        .privacy
        .as_ref()
        .map(|privacy| !privacy.data_leaves_device)
        .unwrap_or(descriptor.provider_type != ProviderType::Cloud)
}

fn evaluate_provider(provider: &ProviderInput, input: &PlanRouteInput) -> Vec<RejectionReason> {
    let descriptor = &provider.descriptor;
    let capabilities = &provider.capabilities;
    let mut reasons = Vec::new();

    if !descriptor.tasks.iter().any(|task| task == &input.task.kind) {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::TaskNotSupported,
            message: format!(
                "Provider '{}' does not support task '{}'.",
                descriptor.id, input.task.kind
            ),
        });
    }

    if !descriptor.supports.run {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::RunNotSupported,
            message: format!("Provider '{}' does not support run().", descriptor.id),
        });
    }

    if matches!(
        input.constraints.privacy,
        Some(PrivacyConstraint::LocalRequired)
    ) && !is_data_private(descriptor)
    {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::PrivacyConstraint,
            message: format!(
                "Provider '{}' does not satisfy local-required privacy.",
                descriptor.id
            ),
        });
    }

    if matches!(
        input.constraints.privacy,
        Some(PrivacyConstraint::CloudRequired)
    ) && descriptor.provider_type != ProviderType::Cloud
    {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::PrivacyConstraint,
            message: format!(
                "Provider '{}' does not satisfy cloud-required privacy.",
                descriptor.id
            ),
        });
    }

    if matches!(input.constraints.cloud, Some(CloudConstraint::Forbidden))
        && descriptor.provider_type == ProviderType::Cloud
    {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::CloudConstraint,
            message: format!(
                "Provider '{}' is cloud-based but cloud execution is forbidden.",
                descriptor.id
            ),
        });
    }

    if matches!(input.constraints.cloud, Some(CloudConstraint::Required))
        && descriptor.provider_type != ProviderType::Cloud
    {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::CloudConstraint,
            message: format!(
                "Provider '{}' is not cloud-based but cloud execution is required.",
                descriptor.id
            ),
        });
    }

    if matches!(input.constraints.network_online, Some(false))
        && descriptor.provider_type == ProviderType::Cloud
    {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::Offline,
            message: format!(
                "Provider '{}' requires cloud connectivity, but the host is offline.",
                descriptor.id
            ),
        });
    }

    if !capabilities.available {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::CapabilityUnavailable,
            message: capabilities.reason.clone().unwrap_or_else(|| {
                format!("Provider '{}' is currently unavailable.", descriptor.id)
            }),
        });
    }

    reasons
}

fn infer_failure_code(
    constraints: &RoutingConstraints,
    rejected_providers: &[RejectedProvider],
) -> RouteFailureCode {
    if rejected_providers.iter().any(|provider| {
        provider
            .reasons
            .iter()
            .any(|reason| reason.code == RejectionReasonCode::Offline)
    }) {
        return RouteFailureCode::Offline;
    }

    if matches!(constraints.cloud, Some(CloudConstraint::Required))
        || matches!(constraints.privacy, Some(PrivacyConstraint::CloudRequired))
    {
        return RouteFailureCode::Unavailable;
    }

    RouteFailureCode::CapabilityMismatch
}
