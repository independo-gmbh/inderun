use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[cfg(target_os = "android")]
use jni::objects::{JClass, JString};
#[cfg(target_os = "android")]
use jni::sys::jstring;
#[cfg(target_os = "android")]
use jni::JNIEnv;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyConstraint {
    LocalRequired,
    LocalPreferred,
    CloudAllowed,
    CloudRequired,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CloudConstraint {
    Forbidden,
    Allowed,
    Required,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OptimizeFor {
    Privacy,
    Latency,
    Cost,
    Balanced,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderType {
    Local,
    Edge,
    Cloud,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RouteFailureCode {
    CapabilityMismatch,
    Offline,
    Unavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RejectionReasonCode {
    TaskNotSupported,
    RunNotSupported,
    PrivacyConstraint,
    CloudConstraint,
    Offline,
    CapabilityUnavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RoutingTask {
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RoutingConstraints {
    #[serde(default)]
    pub privacy: Option<PrivacyConstraint>,
    #[serde(default)]
    pub cloud: Option<CloudConstraint>,
    #[serde(default)]
    pub network_online: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RoutingPreferences {
    #[serde(default)]
    pub optimize_for: Option<OptimizeFor>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRunSupport {
    pub run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPrivacy {
    pub data_leaves_device: bool,
    #[serde(default)]
    pub regions: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderDescriptor {
    pub id: String,
    #[serde(rename = "type")]
    pub provider_type: ProviderType,
    pub supports: ProviderRunSupport,
    pub tasks: Vec<String>,
    #[serde(default)]
    pub privacy: Option<ProviderPrivacy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCapabilitySnapshot {
    pub available: bool,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInput {
    pub descriptor: ProviderDescriptor,
    pub capabilities: ProviderCapabilitySnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PlanRouteInput {
    pub task: RoutingTask,
    pub constraints: RoutingConstraints,
    #[serde(default)]
    pub preferences: RoutingPreferences,
    pub providers: Vec<ProviderInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RouteCandidate {
    pub provider_id: String,
    pub order: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RejectionReason {
    pub code: RejectionReasonCode,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RejectedProvider {
    pub provider_id: String,
    pub reasons: Vec<RejectionReason>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RouteExplanation {
    pub summary: String,
    #[serde(default)]
    pub selected_provider_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RoutePlan {
    #[serde(default)]
    pub selected_provider_id: Option<String>,
    #[serde(default)]
    pub fallback_provider_ids: Vec<String>,
    #[serde(default)]
    pub candidates: Vec<RouteCandidate>,
    #[serde(default)]
    pub rejected_providers: Vec<RejectedProvider>,
    #[serde(default)]
    pub failure_code: Option<RouteFailureCode>,
    pub explanation: RouteExplanation,
}

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

fn plan_route_json_string(input_json: &str) -> Result<String, String> {
    let input =
        serde_json::from_str::<PlanRouteInput>(input_json).map_err(|error| error.to_string())?;
    let output = plan_route(input);
    serde_json::to_string(&output).map_err(|error| error.to_string())
}

/// C FFI boundary: the caller owns and must pass a valid, NUL-terminated pointer.
///
/// # Safety
/// `input_json` must be null or a valid pointer to a NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn inderun_plan_route_json(input_json: *const c_char) -> *mut c_char {
    if input_json.is_null() {
        return CString::new(
            serde_json::json!({
                "selectedProviderId": null,
                "fallbackProviderIds": [],
                "candidates": [],
                "rejectedProviders": [],
                "failureCode": "unavailable",
                "explanation": { "summary": "Missing planner input.", "selectedProviderId": null }
            })
            .to_string(),
        )
        .expect("CString conversion must succeed")
        .into_raw();
    }

    let input = unsafe { CStr::from_ptr(input_json) };
    let response = match input.to_str() {
        Ok(value) => plan_route_json_string(value).unwrap_or_else(error_json),
        Err(error) => error_json(error.to_string()),
    };

    CString::new(response)
        .expect("CString conversion must succeed")
        .into_raw()
}

/// C FFI boundary: takes ownership of and frees a string previously returned by this crate.
///
/// # Safety
/// `value` must be null or a pointer previously returned by `inderun_plan_route_json`
/// (and not already freed).
#[no_mangle]
pub unsafe extern "C" fn inderun_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    unsafe {
        let _ = CString::from_raw(value);
    }
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_app_independo_inderun_core_SharedCoreRoutePlanner_planRouteJsonNative(
    mut env: JNIEnv,
    _class: JClass,
    input_json: JString,
) -> jstring {
    let input = match env.get_string(&input_json) {
        Ok(value) => value.to_string_lossy().into_owned(),
        Err(error) => return new_jstring(&mut env, &error_json(error.to_string())),
    };

    let output = plan_route_json_string(&input).unwrap_or_else(error_json);
    new_jstring(&mut env, &output)
}

#[cfg(target_os = "android")]
fn new_jstring(env: &mut JNIEnv, value: &str) -> jstring {
    env.new_string(value)
        .expect("JNI string conversion must succeed")
        .into_raw()
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn plan_route_json(input_json: &str) -> Result<String, JsValue> {
    plan_route_json_string(input_json).map_err(JsValue::from)
}

fn error_json(message: String) -> String {
    serde_json::json!({
        "selectedProviderId": null,
        "fallbackProviderIds": [],
        "candidates": [],
        "rejectedProviders": [],
        "failureCode": "unavailable",
        "explanation": {
            "summary": format!("Shared route planner error: {message}"),
            "selectedProviderId": null
        }
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
