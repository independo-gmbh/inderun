//! Deterministic route-planning algorithm.
//!
//! [`plan_route`] sorts the candidate providers by placement and preference
//! rank, filters out any that violate the request constraints, and produces a
//! [`RoutePlan`] with a stable selection plus an inspectable explanation.

use std::cmp::Ordering;

use crate::model::*;

pub fn plan_route(input: RoutePlannerInput) -> RoutePlan {
    let mut providers = input.providers.clone();
    providers
        .sort_by(|left, right| compare_inputs(left, right, &input.preferences, &input.constraints));

    let mut candidates = Vec::new();
    let mut rejected_providers = Vec::new();

    for provider in &providers {
        let reasons = evaluate_provider(provider, &input);
        if reasons.is_empty() {
            candidates.push(Candidate {
                provider_id: provider.descriptor.id.clone(),
                order: candidates.len() as i64,
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
            explanation: Explanation {
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
        FailureCode::CapabilityMismatch => format!(
            "No eligible local provider found for task '{}'.",
            input.task.kind
        ),
        FailureCode::Offline => {
            "Cloud execution was blocked because the host is offline.".to_string()
        }
        FailureCode::Unavailable => {
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
        explanation: Explanation {
            summary,
            selected_provider_id: None,
        },
    }
}

fn compare_inputs(
    left: &Provider,
    right: &Provider,
    preferences: &Preferences,
    constraints: &Constraints,
) -> Ordering {
    priority_tuple(left, preferences, constraints)
        .cmp(&priority_tuple(right, preferences, constraints))
        .then_with(|| left.descriptor.id.cmp(&right.descriptor.id))
}

fn priority_tuple(
    provider: &Provider,
    preferences: &Preferences,
    constraints: &Constraints,
) -> (u8, u8) {
    (
        placement_rank(provider, constraints),
        preference_rank(provider, preferences),
    )
}

fn placement_rank(provider: &Provider, constraints: &Constraints) -> u8 {
    let descriptor = &provider.descriptor;

    match constraints.cloud {
        Some(Cloud::Required) => {
            if descriptor.descriptor_type == Type::Cloud {
                0
            } else {
                1
            }
        }
        Some(Cloud::Forbidden) => {
            if descriptor.descriptor_type == Type::Cloud {
                1
            } else {
                0
            }
        }
        Some(Cloud::Allowed) | None => match constraints.privacy {
            Some(PrivacyEnum::LocalRequired) | Some(PrivacyEnum::LocalPreferred) => {
                if is_data_private(descriptor) {
                    0
                } else {
                    1
                }
            }
            Some(PrivacyEnum::CloudRequired) => {
                if descriptor.descriptor_type == Type::Cloud {
                    0
                } else {
                    1
                }
            }
            Some(PrivacyEnum::CloudAllowed) | None => 0,
        },
    }
}

fn preference_rank(provider: &Provider, preferences: &Preferences) -> u8 {
    match preferences.optimize_for {
        Some(OptimizeFor::Privacy) => {
            if is_data_private(&provider.descriptor) {
                0
            } else {
                1
            }
        }
        Some(OptimizeFor::Latency) => match provider.descriptor.descriptor_type {
            Type::Cloud => 0,
            Type::Edge => 1,
            Type::Local => 2,
        },
        Some(OptimizeFor::Cost) | Some(OptimizeFor::Balanced) | None => {
            match provider.descriptor.descriptor_type {
                Type::Local => 0,
                Type::Edge => 1,
                Type::Cloud => 2,
            }
        }
    }
}

fn is_data_private(descriptor: &Descriptor) -> bool {
    descriptor
        .privacy
        .as_ref()
        .map(|privacy| !privacy.data_leaves_device)
        .unwrap_or(descriptor.descriptor_type != Type::Cloud)
}

fn evaluate_provider(provider: &Provider, input: &RoutePlannerInput) -> Vec<Reason> {
    let descriptor = &provider.descriptor;
    let capabilities = &provider.capabilities;
    let mut reasons = Vec::new();

    if !descriptor.tasks.iter().any(|task| task == &input.task.kind) {
        reasons.push(Reason {
            code: Code::TaskNotSupported,
            message: format!(
                "Provider '{}' does not support task '{}'.",
                descriptor.id, input.task.kind
            ),
        });
    }

    if !descriptor.supports.run {
        reasons.push(Reason {
            code: Code::RunNotSupported,
            message: format!("Provider '{}' does not support run().", descriptor.id),
        });
    }

    if matches!(input.constraints.privacy, Some(PrivacyEnum::LocalRequired))
        && !is_data_private(descriptor)
    {
        reasons.push(Reason {
            code: Code::PrivacyConstraint,
            message: format!(
                "Provider '{}' does not satisfy local-required privacy.",
                descriptor.id
            ),
        });
    }

    if matches!(input.constraints.privacy, Some(PrivacyEnum::CloudRequired))
        && descriptor.descriptor_type != Type::Cloud
    {
        reasons.push(Reason {
            code: Code::PrivacyConstraint,
            message: format!(
                "Provider '{}' does not satisfy cloud-required privacy.",
                descriptor.id
            ),
        });
    }

    if matches!(input.constraints.cloud, Some(Cloud::Forbidden))
        && descriptor.descriptor_type == Type::Cloud
    {
        reasons.push(Reason {
            code: Code::CloudConstraint,
            message: format!(
                "Provider '{}' is cloud-based but cloud execution is forbidden.",
                descriptor.id
            ),
        });
    }

    if matches!(input.constraints.cloud, Some(Cloud::Required))
        && descriptor.descriptor_type != Type::Cloud
    {
        reasons.push(Reason {
            code: Code::CloudConstraint,
            message: format!(
                "Provider '{}' is not cloud-based but cloud execution is required.",
                descriptor.id
            ),
        });
    }

    if matches!(input.constraints.network_online, Some(false))
        && descriptor.descriptor_type == Type::Cloud
    {
        reasons.push(Reason {
            code: Code::Offline,
            message: format!(
                "Provider '{}' requires cloud connectivity, but the host is offline.",
                descriptor.id
            ),
        });
    }

    if !capabilities.available {
        reasons.push(Reason {
            code: Code::CapabilityUnavailable,
            message: capabilities.reason.clone().unwrap_or_else(|| {
                format!("Provider '{}' is currently unavailable.", descriptor.id)
            }),
        });
    }

    reasons
}

fn infer_failure_code(
    constraints: &Constraints,
    rejected_providers: &[RejectedProvider],
) -> FailureCode {
    if rejected_providers.iter().any(|provider| {
        provider
            .reasons
            .iter()
            .any(|reason| reason.code == Code::Offline)
    }) {
        return FailureCode::Offline;
    }

    if matches!(constraints.cloud, Some(Cloud::Required))
        || matches!(constraints.privacy, Some(PrivacyEnum::CloudRequired))
    {
        return FailureCode::Unavailable;
    }

    FailureCode::CapabilityMismatch
}
