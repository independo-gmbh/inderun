//! Speech-control negotiation (ADR 025 §2 and §3).
//!
//! The planner asks three things of a requested control on a provider: does
//! the voice it would bind (or the task, when the provider lists no voices)
//! support it at the requested value, which reason explains a provider that
//! cannot bind such a voice, and what the bound candidate must do with each
//! control. This module answers them from the provider's static declarations
//! and dynamic control states alone; [`crate::planner`] decides which voices
//! are asked.
//!
//! Invariants worth preserving:
//!
//! - Unknown is never support. A control satisfies a request only when it is
//!   declared once for the task, in the shape its id requires, with
//!   `lifetime: utterance` and the requested delivery listed, its merged state
//!   for that delivery says `available: true`, and its merged range is known
//!   and contains the value.
//! - The merge is per `(id, delivery)` and field by field: the voice's entry
//!   overlays the task's entry, and nothing is inherited across deliveries. A
//!   state for a delivery the declaration does not list is never read.
//! - Contradictions are refused, never resolved: an id declared twice, two
//!   states for one `(id, delivery)` at one level, or a declaration that
//!   breaks its id's invariant ([`declaration_keeps_invariant`]) make that
//!   control unsupported for the provider, even when the duplicates agree or
//!   the states report a range. Swift and Kotlin hand typed declarations
//!   through serde, not the schema, so the planner checks the invariant itself.
//! - A request without controls, in `prepare` mode, or on a delivery that has
//!   no speech controls (anything but `playback` or `artifact`) has nothing to
//!   negotiate: [`requested_controls`] returns `None`, and no plan changes.
//! - Values are compared, never adjusted. Nothing here clamps or rounds.

use crate::model::*;

/// What one control can do for one request, after the merge: the outcome of
/// the support rule, before the requested value is compared.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ControlSupport {
    /// Available, with a known inclusive range.
    Supported { min: f64, max: f64 },
    /// Not declared once for this delivery with `lifetime: utterance`,
    /// contradictory declarations or states, or merged `available: false`.
    Unsupported,
    /// No merged state says whether it works.
    AvailabilityUnknown,
    /// Available, but no merged range is known.
    RangeUnknown,
}

impl ControlSupport {
    /// Whether the control can be applied at `value`.
    pub(crate) fn admits(&self, value: f64) -> bool {
        matches!(self, ControlSupport::Supported { min, max } if *min <= value && value <= *max)
    }

    /// The reason a candidate omits a control at `value`, or `None` when it
    /// applies it.
    pub(crate) fn omission(&self, value: f64) -> Option<ControlOmissionReason> {
        match self {
            ControlSupport::Supported { .. } if self.admits(value) => None,
            ControlSupport::Supported { .. } => Some(ControlOmissionReason::OutOfRange),
            ControlSupport::Unsupported => Some(ControlOmissionReason::Unsupported),
            ControlSupport::AvailabilityUnknown => Some(ControlOmissionReason::AvailabilityUnknown),
            ControlSupport::RangeUnknown => Some(ControlOmissionReason::RangeUnknown),
        }
    }
}

/// A provider's control metadata for one task: the static declarations of its
/// task capability and the dynamic task-level states. Either may be empty.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct ControlCapability<'a> {
    pub(crate) declarations: &'a [SpeechControlDeclaration],
    pub(crate) states: &'a [SpeechControlState],
}

/// Applies the support rule to control `id` on `delivery`, for `voice` when
/// the candidate binds one and for the task state alone otherwise.
pub(crate) fn control_support(
    capability: ControlCapability<'_>,
    voice: Option<&ProviderVoice>,
    id: &SpeechControlId,
    delivery: &ControlDelivery,
) -> ControlSupport {
    let mut declarations = capability
        .declarations
        .iter()
        .filter(|declaration| &declaration.id == id);
    let (Some(declaration), None) = (declarations.next(), declarations.next()) else {
        return ControlSupport::Unsupported;
    };
    if !declaration_keeps_invariant(declaration)
        || declaration.lifetime != SpeechControlLifetime::Utterance
        || !declaration.deliveries.contains(delivery)
    {
        return ControlSupport::Unsupported;
    }

    let Ok(task_state) = single_state(capability.states, id, delivery) else {
        return ControlSupport::Unsupported;
    };
    let voice_states = voice
        .and_then(|voice| voice.control_states.as_deref())
        .unwrap_or_default();
    let Ok(voice_state) = single_state(voice_states, id, delivery) else {
        return ControlSupport::Unsupported;
    };

    let available = voice_state
        .and_then(|state| state.available)
        .or_else(|| task_state.and_then(|state| state.available));
    let range = voice_state
        .and_then(|state| state.range.as_ref())
        .or_else(|| task_state.and_then(|state| state.range.as_ref()));
    match (available, range) {
        (None, _) => ControlSupport::AvailabilityUnknown,
        (Some(false), _) => ControlSupport::Unsupported,
        (Some(true), None) => ControlSupport::RangeUnknown,
        (Some(true), Some(range)) => ControlSupport::Supported {
            min: range.min,
            max: range.max,
        },
    }
}

/// Whether `declaration` has the shape its id requires, the schema's `allOf`
/// on `speechControlDeclaration` in `provider-descriptor.schema.json`: rate and
/// pitch are `number` controls of the `synthesis` phase, volume a `number`
/// control of the `playback` phase, and a `playback`-phase control lists only
/// the `playback` delivery. A declaration that breaks it is contradictory and
/// makes its control unsupported for every delivery.
pub(crate) fn declaration_keeps_invariant(declaration: &SpeechControlDeclaration) -> bool {
    let phase = match declaration.id {
        SpeechControlId::SpeechSpeakingRate | SpeechControlId::SpeechPitch => {
            SpeechControlPhase::Synthesis
        }
        SpeechControlId::PlaybackVolume => SpeechControlPhase::Playback,
    };
    declaration.value_kind == SpeechControlValueKind::Number
        && declaration.phase == phase
        && (phase != SpeechControlPhase::Playback
            || declaration
                .deliveries
                .iter()
                .all(|delivery| *delivery == ControlDelivery::Playback))
}

/// The one state for `(id, delivery)` in `states`, `Ok(None)` when there is
/// none, and `Err(())` when there are two or more, which is a declaration
/// error rather than something to pick from.
fn single_state<'a>(
    states: &'a [SpeechControlState],
    id: &SpeechControlId,
    delivery: &ControlDelivery,
) -> Result<Option<&'a SpeechControlState>, ()> {
    let mut matching = states
        .iter()
        .filter(|state| &state.id == id && &state.delivery == delivery);
    match (matching.next(), matching.next()) {
        (first, None) => Ok(first),
        (Some(_), Some(_)) | (None, Some(_)) => Err(()),
    }
}

/// The controls a request asks the planner to negotiate, and the delivery
/// they are negotiated for.
#[derive(Debug, Clone)]
pub(crate) struct RequestedControls<'a> {
    delivery: ControlDelivery,
    controls: &'a [ControlRequirement],
}

/// The request's controls, or `None` when there is nothing to negotiate: no
/// controls, `prepare` mode (a prepare request carries none), or a delivery
/// other than `playback` or `artifact`.
pub(crate) fn requested_controls(input: &RoutePlannerInput) -> Option<RequestedControls<'_>> {
    if matches!(input.interaction_mode, Some(InteractionMode::Prepare)) {
        return None;
    }
    let controls = input
        .task
        .controls
        .as_deref()
        .filter(|controls| !controls.is_empty())?;
    let delivery = match input.task.delivery.as_ref()?.mode {
        OutputDelivery::Playback => ControlDelivery::Playback,
        OutputDelivery::Artifact => ControlDelivery::Artifact,
        OutputDelivery::Inline => return None,
    };
    Some(RequestedControls { delivery, controls })
}

impl RequestedControls<'_> {
    fn support(
        &self,
        capability: ControlCapability<'_>,
        voice: Option<&ProviderVoice>,
        control: &ControlRequirement,
    ) -> ControlSupport {
        control_support(capability, voice, &control.id, &self.delivery)
    }

    fn with_requirement(
        &self,
        requirement: RequirementLevel,
    ) -> impl Iterator<Item = &ControlRequirement> {
        self.controls
            .iter()
            .filter(move |control| control.requirement == requirement)
    }

    /// Whether every required control can be applied at its value on `voice`
    /// (on the task state when `voice` is `None`).
    pub(crate) fn meets_required(
        &self,
        capability: ControlCapability<'_>,
        voice: Option<&ProviderVoice>,
    ) -> bool {
        self.with_requirement(RequirementLevel::Required)
            .all(|control| {
                self.support(capability, voice, control)
                    .admits(control.value)
            })
    }

    /// How many preferred controls cannot be applied at their value on
    /// `voice` (on the task state when `voice` is `None`). Lower ranks first.
    pub(crate) fn unmet_preferred(
        &self,
        capability: ControlCapability<'_>,
        voice: Option<&ProviderVoice>,
    ) -> usize {
        self.with_requirement(RequirementLevel::Preferred)
            .filter(|control| {
                !self
                    .support(capability, voice, control)
                    .admits(control.value)
            })
            .count()
    }

    /// The number of preferred controls, which is what a provider that cannot
    /// serve the task leaves unmet.
    pub(crate) fn preferred_count(&self) -> usize {
        self.with_requirement(RequirementLevel::Preferred).count()
    }

    /// What a candidate bound to `voice` (the task state when `None`) must do
    /// with each requested control, in request order. A required control is
    /// always `apply` here, because only a provider that meets every required
    /// control on its bound voice becomes a candidate.
    pub(crate) fn plan(
        &self,
        capability: ControlCapability<'_>,
        voice: Option<&ProviderVoice>,
    ) -> Vec<ControlApplicationPlan> {
        self.controls
            .iter()
            .map(|control| {
                let reason = self
                    .support(capability, voice, control)
                    .omission(control.value);
                ControlApplicationPlan {
                    decision: if reason.is_none() {
                        ControlDecision::Apply
                    } else {
                        ControlDecision::Omit
                    },
                    id: control.id.clone(),
                    reason,
                    requirement: control.requirement.clone(),
                    value: control.value,
                }
            })
            .collect()
    }

    /// Why a provider cannot serve the required controls, or nothing when it
    /// can. `voices` holds the voices the provider could otherwise bind (those
    /// that fit the locale, required traits, privacy and readiness), or is
    /// `None` when it lists no voices and its task state alone decides.
    ///
    /// A required control that none of them supports at its value on its own
    /// gets its own reason, in request order: `speech_control_out_of_range`
    /// when one of them supports it with another range, else
    /// `speech_control_unsupported`. When every required control is met by
    /// some voice but no voice meets them all, one
    /// `speech_control_unsupported` reason says so. A request without required
    /// controls never gets a reason, whatever the voices: preferences rank,
    /// never reject.
    pub(crate) fn rejection_reasons(
        &self,
        provider_id: &str,
        capability: ControlCapability<'_>,
        voices: Option<&[&ProviderVoice]>,
    ) -> Vec<Reason> {
        if self
            .with_requirement(RequirementLevel::Required)
            .next()
            .is_none()
        {
            return Vec::new();
        }
        let delivery = control_delivery_name(&self.delivery);
        let candidates: Vec<Option<&ProviderVoice>> = match voices {
            None => vec![None],
            Some(voices) => voices.iter().map(|voice| Some(*voice)).collect(),
        };
        if candidates
            .iter()
            .any(|voice| self.meets_required(capability, *voice))
        {
            return Vec::new();
        }

        let mut reasons = Vec::new();
        for control in self.with_requirement(RequirementLevel::Required) {
            let supports: Vec<ControlSupport> = candidates
                .iter()
                .map(|voice| self.support(capability, *voice, control))
                .collect();
            if supports.iter().any(|support| support.admits(control.value)) {
                continue;
            }
            let name = control_name(&control.id);
            let out_of_range = supports
                .iter()
                .any(|support| matches!(support, ControlSupport::Supported { .. }));
            reasons.push(match (out_of_range, voices.is_some()) {
                (true, true) => Reason {
                    code: Code::SpeechControlOutOfRange,
                    message: format!(
                        "Provider '{provider_id}': {name} {} is outside every voice's range for {delivery}.",
                        control.value
                    ),
                },
                (true, false) => Reason {
                    code: Code::SpeechControlOutOfRange,
                    message: format!(
                        "Provider '{provider_id}': {name} {} is outside the supported range for {delivery}.",
                        control.value
                    ),
                },
                (false, true) => Reason {
                    code: Code::SpeechControlUnsupported,
                    message: format!(
                        "Provider '{provider_id}': no voice supports required {name} for {delivery}."
                    ),
                },
                (false, false) => Reason {
                    code: Code::SpeechControlUnsupported,
                    message: format!(
                        "Provider '{provider_id}': required {name} is not supported for {delivery}."
                    ),
                },
            });
        }
        if reasons.is_empty() {
            reasons.push(Reason {
                code: Code::SpeechControlUnsupported,
                message: format!(
                    "Provider '{provider_id}': no single voice supports every required speech control for {delivery}."
                ),
            });
        }
        reasons
    }
}

/// The wire id of a control, as messages name it.
fn control_name(id: &SpeechControlId) -> &'static str {
    match id {
        SpeechControlId::SpeechSpeakingRate => "speech.speakingRate",
        SpeechControlId::SpeechPitch => "speech.pitch",
        SpeechControlId::PlaybackVolume => "playback.volume",
    }
}

fn control_delivery_name(delivery: &ControlDelivery) -> &'static str {
    match delivery {
        ControlDelivery::Playback => "playback",
        ControlDelivery::Artifact => "artifact",
    }
}
