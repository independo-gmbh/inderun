//! Deterministic route-planning algorithm.
//!
//! [`plan_route`] sorts the candidate providers by placement, model-profile,
//! preference and locale rank, filters out any that violate the request
//! constraints, binds each candidate to the voice it must use when the
//! provider lists its voices, and produces a [`RoutePlan`] with a stable
//! selection plus an inspectable explanation.
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
//! - Routing matches the whole task, not just its kind. A provider's
//!   `taskCapabilities` entry for the requested kind decides inputs, modes,
//!   output delivery, media types and locales; a descriptor without
//!   `taskCapabilities` is projected onto `text_to_text` alone, so it keeps its
//!   exact pre-task-capability plans and is never routed a non-text task.
//! - A requirement is only enforced when it can be verified, with one
//!   exception: unknown locales are not rejected (the provider must refuse
//!   before committing), but a required voice or media type that the provider
//!   does not declare is, because a hard requirement must be checkable.
//! - Preferences rank or bind, never reject. The locale region ranks after
//!   every explicit priority; a preferred voice only shapes which listed voice
//!   a candidate is bound to, and that voice is always chosen inside the
//!   privacy policy, so `local_required` binds the voice that speaks.
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
                voice: select_voice(provider, &input),
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

fn priority_tuple(provider: &Provider, input: &RoutePlannerInput) -> (u8, usize, u8, u8) {
    (
        placement_rank(provider, input),
        profile_rank(provider, input.model_profile.as_ref()),
        preference_rank(provider, input),
        locale_rank(provider, input),
    )
}

/// The requested locale's region is a preference under `language` matching, so
/// a provider known to offer the exact tag ranks ahead of one that only offers
/// another region of the language (or cannot say). It ranks after every
/// explicit routing priority, and a request without a locale ranks everyone 0,
/// so text plans are unaffected.
fn locale_rank(provider: &Provider, input: &RoutePlannerInput) -> u8 {
    let Some(locale) = &input.task.locale else {
        return 0;
    };
    let Some(task) = resolve_task(provider, &input.task.kind) else {
        return 1;
    };
    let private = is_data_private(provider, &input.task.kind);
    let exact = |tag: &str| tag.eq_ignore_ascii_case(&locale.tag);
    let offers_exact = match task.voices() {
        Some(voices) => voices
            .iter()
            .any(|voice| exact(&voice.locale) && voice_is_usable(voice, input, private)),
        None => task
            .known_locales()
            .is_some_and(|locales| locales.iter().any(|tag| exact(tag))),
    };
    if offers_exact { 0 } else { 1 }
}

/// Picks the voice a candidate must use, so the planner's privacy decision
/// binds the voice that actually speaks rather than only the provider. Only
/// voices that satisfy the request's locale, required traits and privacy
/// qualify; among them a preferred gender wins, then the exact locale region,
/// then on-device before network, then the provider's own listing order.
fn select_voice(provider: &Provider, input: &RoutePlannerInput) -> Option<ProviderVoice> {
    if input.task.locale.is_none() && input.task.voice.is_none() {
        return None;
    }
    let task = resolve_task(provider, &input.task.kind)?;
    let private = is_data_private(provider, &input.task.kind);
    let preferred_gender = input
        .task
        .voice
        .as_ref()
        .and_then(|voice| voice.gender.as_ref());

    task.voices()?
        .iter()
        .filter(|voice| voice_fits(voice, input) && voice_is_usable(voice, input, private))
        .min_by_key(|voice| {
            (
                preferred_gender.is_some_and(|gender| voice.gender.as_ref() != Some(gender)),
                input
                    .task
                    .locale
                    .as_ref()
                    .is_some_and(|locale| !voice.locale.eq_ignore_ascii_case(&locale.tag)),
                !voice_is_local(voice, private),
            )
        })
        .cloned()
}

/// Whether `voice` satisfies the request's locale and required voice traits.
/// A preferred trait is never a filter.
fn voice_fits(voice: &ProviderVoice, input: &RoutePlannerInput) -> bool {
    let locale_fits = input
        .task
        .locale
        .as_ref()
        .is_none_or(|locale| locale_matches(&voice.locale, locale));
    let traits_fit = input.task.voice.as_ref().is_none_or(|requirement| {
        requirement.requirement != RequirementLevel::Required
            || requirement
                .gender
                .as_ref()
                .is_none_or(|gender| voice.gender.as_ref() == Some(gender))
    });
    locale_fits && traits_fit
}

/// Under local-required privacy, only a voice that keeps data on the device
/// may be used.
fn voice_is_usable(voice: &ProviderVoice, input: &RoutePlannerInput, task_private: bool) -> bool {
    !matches!(input.constraints.privacy, Some(Privacy::LocalRequired))
        || voice_is_local(voice, task_private)
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

fn placement_rank(provider: &Provider, input: &RoutePlannerInput) -> u8 {
    let descriptor = &provider.descriptor;
    let constraints = &input.constraints;

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
                if is_data_private(provider, &input.task.kind) {
                    0
                } else {
                    1
                }
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

fn preference_rank(provider: &Provider, input: &RoutePlannerInput) -> u8 {
    match input.preferences.optimize_for {
        Some(OptimizeFor::Privacy) => {
            if is_data_private(provider, &input.task.kind) {
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

/// Whether the provider keeps request content on the device for this task. A
/// task capability's own `privacy` overrides the descriptor's; without either,
/// every non-cloud provider counts as private.
fn is_data_private(provider: &Provider, kind: &str) -> bool {
    let descriptor = &provider.descriptor;
    descriptor
        .task_capabilities
        .as_ref()
        .and_then(|entries| entries.iter().find(|entry| entry.kind == kind))
        .and_then(|entry| entry.privacy.as_ref())
        .or(descriptor.privacy.as_ref())
        .map(|privacy| !privacy.data_leaves_device)
        .unwrap_or(descriptor.provider_descriptor_type != ProviderType::Cloud)
}

/// The only task a descriptor without `taskCapabilities` is routed for.
const LEGACY_TASK: &str = "text_to_text";

/// A provider's capabilities for the requested task: its explicit task
/// capability, or the projection a legacy descriptor gets for
/// [`LEGACY_TASK`], plus the matching dynamic per-task check.
struct ResolvedTask<'a> {
    inputs: Vec<TaskInputKind>,
    run: bool,
    stream: bool,
    outputs: Vec<ProviderTaskOutput>,
    static_locales: Option<&'a [String]>,
    dynamic: Option<&'a ProviderTaskAvailability>,
}

impl<'a> ResolvedTask<'a> {
    /// The voices the provider lists for the task right now, if it lists any.
    fn voices(&self) -> Option<&'a [ProviderVoice]> {
        self.dynamic.and_then(|dynamic| dynamic.voices.as_deref())
    }

    /// Locales known without voices: the dynamic list, else the static one.
    fn known_locales(&self) -> Option<&'a [String]> {
        self.dynamic
            .and_then(|dynamic| dynamic.locales.as_deref())
            .or(self.static_locales)
    }
}

/// Resolves the provider's capabilities for `kind`, or `None` when it cannot
/// serve the task. An explicit `taskCapabilities` list is authoritative. A
/// legacy descriptor is projected onto [`LEGACY_TASK`] alone — text in, inline
/// text out, modes from `supports` — so listing any other kind in `tasks`
/// without a task capability never makes a provider eligible for it.
fn resolve_task<'a>(provider: &'a Provider, kind: &str) -> Option<ResolvedTask<'a>> {
    let descriptor = &provider.descriptor;
    let dynamic = provider
        .capabilities
        .task_capabilities
        .as_ref()
        .and_then(|entries| entries.iter().find(|entry| entry.kind == kind));

    match &descriptor.task_capabilities {
        Some(entries) => {
            let entry = entries.iter().find(|entry| entry.kind == kind)?;
            Some(ResolvedTask {
                inputs: entry.inputs.clone(),
                run: entry.interaction.run,
                stream: entry.interaction.stream,
                outputs: entry.outputs.clone(),
                static_locales: entry.locales.as_deref(),
                dynamic,
            })
        }
        None if kind == LEGACY_TASK && descriptor.tasks.iter().any(|task| task == kind) => {
            Some(ResolvedTask {
                inputs: vec![TaskInputKind::Text],
                run: descriptor.supports.run,
                stream: descriptor.supports.streaming,
                outputs: vec![ProviderTaskOutput {
                    delivery: OutputDelivery::Inline,
                    media_types: None,
                }],
                static_locales: None,
                dynamic,
            })
        }
        None => None,
    }
}

/// Whether using `voice` keeps data on the device. An absent
/// `networkRequired` inherits the task's privacy posture.
fn voice_is_local(voice: &ProviderVoice, task_private: bool) -> bool {
    match voice.network_required {
        Some(network_required) => !network_required,
        None => task_private,
    }
}

/// BCP 47 comparison, case-insensitive. `language` compares the primary
/// language subtag only, so `de-AT` is satisfied by `de-DE`; `exact` compares
/// the whole tag.
fn locale_matches(available: &str, requirement: &LocaleRequirement) -> bool {
    match requirement.locale_requirement_match {
        LocaleMatch::Exact => available.eq_ignore_ascii_case(&requirement.tag),
        LocaleMatch::Language => {
            primary_subtag(available).eq_ignore_ascii_case(primary_subtag(&requirement.tag))
        }
    }
}

fn primary_subtag(tag: &str) -> &str {
    tag.split(['-', '_']).next().unwrap_or(tag)
}

fn input_kind_name(kind: &TaskInputKind) -> &'static str {
    match kind {
        TaskInputKind::Text => "text",
        TaskInputKind::Image => "image",
        TaskInputKind::Audio => "audio",
    }
}

fn delivery_name(delivery: &OutputDelivery) -> &'static str {
    match delivery {
        OutputDelivery::Inline => "inline",
        OutputDelivery::Playback => "playback",
        OutputDelivery::Artifact => "artifact",
    }
}

fn wants_stream(input: &RoutePlannerInput) -> bool {
    matches!(input.interaction_mode, Some(InteractionMode::Stream))
}

/// Collects every reason the provider cannot serve the request, in a fixed
/// order: task, model profile, input kinds, interaction mode, output delivery,
/// media type, locale, voice, placement, availability. An empty list means the
/// provider is a candidate.
fn evaluate_provider(provider: &Provider, input: &RoutePlannerInput) -> Vec<Reason> {
    let descriptor = &provider.descriptor;
    let capabilities = &provider.capabilities;
    let kind = &input.task.kind;
    let wants_stream = wants_stream(input);
    let task = resolve_task(provider, kind);
    let private = is_data_private(provider, kind);
    let local_required = matches!(input.constraints.privacy, Some(Privacy::LocalRequired));
    // Only a provider that describes its tasks explicitly gets task-qualified
    // messages, so legacy text plans keep their exact wording.
    let for_task = if descriptor.task_capabilities.is_some() {
        format!(" for task '{}'", kind)
    } else {
        String::new()
    };
    let mut reasons = Vec::new();

    if task.is_none() {
        let message = if descriptor.task_capabilities.is_none()
            && kind != LEGACY_TASK
            && descriptor.tasks.iter().any(|listed| listed == kind)
        {
            format!(
                "Provider '{}' lists task '{}' but declares no task capability for it; a descriptor without taskCapabilities is only routed for '{}'.",
                descriptor.id, kind, LEGACY_TASK
            )
        } else {
            format!(
                "Provider '{}' does not support task '{}'.",
                descriptor.id, kind
            )
        };
        reasons.push(Reason {
            code: Code::TaskNotSupported,
            message,
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

    if let (Some(task), Some(required)) = (&task, &input.task.inputs) {
        let missing = required
            .iter()
            .filter(|input_kind| !task.inputs.contains(input_kind))
            .map(input_kind_name)
            .collect::<Vec<_>>();
        if !missing.is_empty() {
            reasons.push(Reason {
                code: Code::InputNotSupported,
                message: format!(
                    "Provider '{}' does not accept {} input for task '{}'.",
                    descriptor.id,
                    missing.join(", "),
                    kind
                ),
            });
        }
    }

    // Without a task capability the provider-level flags still decide the mode
    // reasons, so an unsupported task reports the same mode reasons it always did.
    let (run_supported, stream_supported) = match &task {
        Some(task) => (task.run, task.stream),
        None => (descriptor.supports.run, descriptor.supports.streaming),
    };

    if !wants_stream && !run_supported {
        reasons.push(Reason {
            code: Code::RunNotSupported,
            message: format!(
                "Provider '{}' does not support run(){}.",
                descriptor.id, for_task
            ),
        });
    }

    if wants_stream {
        let task_dynamic = task.as_ref().and_then(|task| task.dynamic);
        if !stream_supported {
            reasons.push(Reason {
                code: Code::StreamingNotSupported,
                message: format!(
                    "Provider '{}' does not support streaming (Mode 2){}.",
                    descriptor.id, for_task
                ),
            });
        } else if let Some(dynamic) = task_dynamic
            && matches!(dynamic.streaming_available, Some(false))
        {
            reasons.push(Reason {
                code: Code::StreamingUnavailable,
                message: dynamic
                    .streaming_unavailable_reason
                    .clone()
                    .unwrap_or_else(|| {
                        format!(
                            "Provider '{}' cannot stream{} in the current host environment.",
                            descriptor.id, for_task
                        )
                    }),
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

    if let (Some(task), Some(delivery)) = (&task, &input.task.delivery) {
        let matching = task
            .outputs
            .iter()
            .filter(|output| output.delivery == delivery.mode)
            .collect::<Vec<_>>();
        if matching.is_empty() {
            reasons.push(Reason {
                code: Code::OutputDeliveryNotSupported,
                message: format!(
                    "Provider '{}' cannot deliver task '{}' as {}.",
                    descriptor.id,
                    kind,
                    delivery_name(&delivery.mode)
                ),
            });
        } else if let Some(wanted) = delivery
            .media_types
            .as_ref()
            .filter(|wanted| !wanted.is_empty())
        {
            // A required media type is a hard requirement, so an output that
            // does not declare its media types cannot satisfy it.
            let produces_wanted = matching.iter().any(|output| {
                output.media_types.as_ref().is_some_and(|declared| {
                    declared
                        .iter()
                        .any(|have| wanted.iter().any(|want| want.eq_ignore_ascii_case(have)))
                })
            });
            if !produces_wanted {
                reasons.push(Reason {
                    code: Code::OutputFormatNotSupported,
                    message: format!(
                        "Provider '{}' produces none of the required media types ({}) for task '{}'.",
                        descriptor.id,
                        wanted.join(", "),
                        kind
                    ),
                });
            }
        }
    }

    if let Some(task) = &task {
        let voices = task.voices();
        // Under local-required privacy, a voice that sends data off the device
        // does not count; when only such voices fit, the refusal is a privacy one.
        let usable = |voice: &ProviderVoice| voice_is_usable(voice, input, private);

        if let Some(locale) = &input.task.locale {
            match voices {
                Some(voices) => {
                    let fits = |voice: &&ProviderVoice| locale_matches(&voice.locale, locale);
                    if !voices.iter().any(|voice| fits(&voice)) {
                        reasons.push(locale_not_supported(&descriptor.id, locale, kind));
                    } else if !voices.iter().filter(fits).any(&usable) {
                        reasons.push(Reason {
                            code: Code::PrivacyConstraint,
                            message: format!(
                                "Provider '{}' offers locale '{}' only through voices that send data off the device, which local-required privacy excludes.",
                                descriptor.id, locale.tag
                            ),
                        });
                    }
                }
                None => {
                    // Unknown locales are not rejected: nothing can be checked, so
                    // the provider has to refuse before committing instead.
                    if let Some(locales) = task.known_locales()
                        && !locales
                            .iter()
                            .any(|available| locale_matches(available, locale))
                    {
                        reasons.push(locale_not_supported(&descriptor.id, locale, kind));
                    }
                }
            }
        }

        if let Some(voice) = &input.task.voice
            && voice.requirement == RequirementLevel::Required
        {
            match voices {
                // A requirement has to be verifiable, so a provider that cannot
                // list its voices cannot satisfy one.
                None => reasons.push(Reason {
                    code: Code::VoiceNotAvailable,
                    message: format!(
                        "Provider '{}' cannot list its voices for task '{}', so a required voice cannot be verified.",
                        descriptor.id, kind
                    ),
                }),
                Some(voices) => {
                    let fits = |candidate: &&ProviderVoice| voice_fits(candidate, input);
                    if !voices.iter().any(|candidate| fits(&candidate)) {
                        reasons.push(Reason {
                            code: Code::VoiceNotAvailable,
                            message: format!(
                                "Provider '{}' has no voice with the required traits for task '{}'.",
                                descriptor.id, kind
                            ),
                        });
                    } else if !voices.iter().filter(fits).any(&usable) {
                        reasons.push(Reason {
                            code: Code::PrivacyConstraint,
                            message: format!(
                                "Provider '{}' has the required voice only as one that sends data off the device, which local-required privacy excludes.",
                                descriptor.id
                            ),
                        });
                    }
                }
            }
        }
    }

    if local_required && !private {
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
    } else if let Some(dynamic) = task.as_ref().and_then(|task| task.dynamic)
        && matches!(dynamic.available, Some(false))
    {
        reasons.push(Reason {
            code: Code::CapabilityUnavailable,
            message: dynamic.reason.clone().unwrap_or_else(|| {
                format!(
                    "Provider '{}' cannot run task '{}' on this host right now.",
                    descriptor.id, kind
                )
            }),
        });
    }

    reasons
}

fn locale_not_supported(provider_id: &str, locale: &LocaleRequirement, kind: &str) -> Reason {
    Reason {
        code: Code::LocaleNotSupported,
        message: format!(
            "Provider '{}' does not offer locale '{}' for task '{}'.",
            provider_id, locale.tag, kind
        ),
    }
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
