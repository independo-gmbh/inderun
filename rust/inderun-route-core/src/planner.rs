//! Deterministic route-planning algorithm.
//!
//! [`plan_route`] sorts the candidate providers by placement, model-profile,
//! and preference rank, filters out any that violate the request constraints,
//! and produces a
//! [`RoutePlan`] with a stable selection plus an inspectable explanation.
//!
//! Invariants worth preserving:
//!
//! - The requested interaction mode filters providers; it never reorders them.
//!   The stream-mode candidate list is therefore always a subsequence of the
//!   run-mode one for the same input, which is what keeps Mode 1 stable while
//!   Mode 2 evolves.
//! - The descriptor and dynamic capabilities are the provider schemas
//!   themselves (`provider-descriptor`, `provider-dynamic-capabilities`), so
//!   every static flag is present. Absent dynamic flags inherit the static
//!   declaration; they never mean "capable" on their own.
//! - A static rejection wins over a dynamic one: a provider that never declared
//!   streaming is reported as `streaming_not_supported`, and only a provider
//!   that did declare it can be reported as `streaming_unavailable`. Emitting
//!   both would make the two codes useless for telling static from dynamic.
//! - A model profile is an allow-list and an order, applied inside placement:
//!   the profile position ranks providers after `placement_rank`, so a profile
//!   can never pull a cloud provider ahead of a local one that placement puts
//!   first. Absent profile means "auto": no allow-list and rank 0 for everyone,
//!   which keeps every pre-profile plan unchanged.
//! - `infer_failure_code` keeps `offline` ahead of `capability_mismatch`: an
//!   offline host is the more actionable diagnostic even when the surviving
//!   providers also failed a mode check.

use std::cmp::Ordering;

use crate::model::*;

pub fn plan_route(input: RoutePlannerInput) -> RoutePlan {
    let wants_stream = wants_stream(&input);
    let mut providers = input.providers.clone();
    providers.sort_by(|left, right| compare_inputs(left, right, &input));

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
                summary: if wants_stream {
                    format!(
                        "Selected streaming provider '{}' deterministically from {} eligible candidate(s).",
                        selected_provider_id, candidate_count
                    )
                } else {
                    format!(
                        "Selected provider '{}' deterministically from {} eligible candidate(s).",
                        selected_provider_id, candidate_count
                    )
                },
                selected_provider_id: Some(selected_provider_id),
            },
        };
    }

    let failure_code = infer_failure_code(&input.constraints, &rejected_providers);
    let summary = match failure_code {
        FailureCode::CapabilityMismatch if wants_stream => format!(
            "No provider capable of streaming was found for task '{}'.",
            input.task.kind
        ),
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

fn compare_inputs(left: &Provider, right: &Provider, input: &RoutePlannerInput) -> Ordering {
    priority_tuple(left, input)
        .cmp(&priority_tuple(right, input))
        .then_with(|| left.descriptor.id.cmp(&right.descriptor.id))
}

fn priority_tuple(provider: &Provider, input: &RoutePlannerInput) -> (u8, usize, u8) {
    (
        placement_rank(provider, &input.constraints),
        profile_rank(provider, input.model_profile.as_ref()),
        preference_rank(provider, &input.preferences),
    )
}

/// Position of the provider in the requested model profile. Providers outside
/// the profile sort last; they are rejected anyway, so their rank only keeps
/// the rejected list in a stable order.
fn profile_rank(provider: &Provider, profile: Option<&ModelProfile>) -> usize {
    match profile {
        None => 0,
        Some(profile) => profile
            .target_ids
            .iter()
            .position(|id| id == &provider.descriptor.id)
            .unwrap_or(usize::MAX),
    }
}

fn placement_rank(provider: &Provider, constraints: &Constraints) -> u8 {
    let descriptor = &provider.descriptor;

    match constraints.cloud {
        Some(Cloud::Required) => {
            if descriptor.provider_descriptor_type == ProviderType::Cloud {
                0
            } else {
                1
            }
        }
        Some(Cloud::Forbidden) => {
            if descriptor.provider_descriptor_type == ProviderType::Cloud {
                1
            } else {
                0
            }
        }
        Some(Cloud::Allowed) | None => match constraints.privacy {
            Some(Privacy::LocalRequired) | Some(Privacy::LocalPreferred) => {
                if is_data_private(descriptor) { 0 } else { 1 }
            }
            Some(Privacy::CloudRequired) => {
                if descriptor.provider_descriptor_type == ProviderType::Cloud {
                    0
                } else {
                    1
                }
            }
            Some(Privacy::CloudAllowed) | None => 0,
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
        Some(OptimizeFor::Latency) => match provider.descriptor.provider_descriptor_type {
            ProviderType::Cloud => 0,
            ProviderType::Edge => 1,
            ProviderType::Local => 2,
        },
        Some(OptimizeFor::Cost) | Some(OptimizeFor::Balanced) | None => {
            match provider.descriptor.provider_descriptor_type {
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
        .unwrap_or(descriptor.provider_descriptor_type != ProviderType::Cloud)
}

fn wants_stream(input: &RoutePlannerInput) -> bool {
    matches!(input.interaction_mode, Some(InteractionMode::Stream))
}

fn evaluate_provider(provider: &Provider, input: &RoutePlannerInput) -> Vec<Reason> {
    let descriptor = &provider.descriptor;
    let capabilities = &provider.capabilities;
    let wants_stream = wants_stream(input);
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

    if let Some(profile) = &input.model_profile
        && !profile.target_ids.iter().any(|id| id == &descriptor.id)
    {
        reasons.push(Reason {
            code: Code::NotInModelProfile,
            message: format!(
                "Provider '{}' is not listed in model profile '{}'.",
                descriptor.id, profile.name
            ),
        });
    }

    if !wants_stream && !descriptor.supports.run {
        reasons.push(Reason {
            code: Code::RunNotSupported,
            message: format!("Provider '{}' does not support run().", descriptor.id),
        });
    }

    if wants_stream {
        if !descriptor.supports.streaming {
            reasons.push(Reason {
                code: Code::StreamingNotSupported,
                message: format!(
                    "Provider '{}' does not support streaming (Mode 2).",
                    descriptor.id
                ),
            });
        } else if matches!(capabilities.streaming_available, Some(false)) {
            reasons.push(Reason {
                code: Code::StreamingUnavailable,
                message: capabilities
                    .streaming_unavailable_reason
                    .clone()
                    .unwrap_or_else(|| {
                        format!(
                            "Provider '{}' cannot stream in the current host environment.",
                            descriptor.id
                        )
                    }),
            });
        }
    }

    if matches!(input.constraints.privacy, Some(Privacy::LocalRequired))
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

    if matches!(input.constraints.privacy, Some(Privacy::CloudRequired))
        && descriptor.provider_descriptor_type != ProviderType::Cloud
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
        && descriptor.provider_descriptor_type == ProviderType::Cloud
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
        && descriptor.provider_descriptor_type != ProviderType::Cloud
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
        && descriptor.provider_descriptor_type == ProviderType::Cloud
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
        || matches!(constraints.privacy, Some(Privacy::CloudRequired))
    {
        return FailureCode::Unavailable;
    }

    FailureCode::CapabilityMismatch
}
