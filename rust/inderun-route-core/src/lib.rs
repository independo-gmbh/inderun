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
pub enum ExecutionTarget {
    OnDevice,
    Cloud,
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
    ExecutionTargetMismatch,
    Offline,
    CapabilityUnavailable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RoutingTask {
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RoutingConstraints {
    pub execution_target: ExecutionTarget,
    #[serde(default)]
    pub network_online: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RoutingPreferences {
    #[serde(default)]
    pub preferred_provider_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRunSupport {
    pub run: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderDescriptor {
    pub id: String,
    #[serde(rename = "type")]
    pub provider_type: ProviderType,
    pub supports: ProviderRunSupport,
    pub tasks: Vec<String>,
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
    providers.sort_by(|left, right| compare_inputs(left, right, &input.preferences));

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
                    selected_provider_id,
                    candidate_count
                ),
                selected_provider_id: Some(selected_provider_id),
            },
        };
    }

    let failure_code = infer_failure_code(&input.constraints);
    let summary = match failure_code {
        RouteFailureCode::CapabilityMismatch => format!(
            "No eligible on-device provider found for task '{}'.",
            input.task.kind
        ),
        RouteFailureCode::Offline => {
            "Cloud execution requested, but the host is offline.".to_string()
        }
        RouteFailureCode::Unavailable => {
            format!("No eligible cloud provider found for task '{}'.", input.task.kind)
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
) -> Ordering {
    let left_rank = preferred_rank(preferences, &left.descriptor.id);
    let right_rank = preferred_rank(preferences, &right.descriptor.id);
    left_rank
        .cmp(&right_rank)
        .then_with(|| left.descriptor.id.cmp(&right.descriptor.id))
}

fn preferred_rank(preferences: &RoutingPreferences, provider_id: &str) -> usize {
    preferences
        .preferred_provider_ids
        .iter()
        .position(|id| id == provider_id)
        .unwrap_or(usize::MAX)
}

fn evaluate_provider(provider: &ProviderInput, input: &PlanRouteInput) -> Vec<RejectionReason> {
    let descriptor = &provider.descriptor;
    let capabilities = &provider.capabilities;
    let mut reasons = Vec::new();

    if !descriptor.tasks.iter().any(|task| task == &input.task.kind) {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::TaskNotSupported,
            message: format!("Provider '{}' does not support task '{}'.", descriptor.id, input.task.kind),
        });
    }

    if !descriptor.supports.run {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::RunNotSupported,
            message: format!("Provider '{}' does not support run().", descriptor.id),
        });
    }

    let expected_type = match input.constraints.execution_target {
        ExecutionTarget::OnDevice => ProviderType::Local,
        ExecutionTarget::Cloud => ProviderType::Cloud,
    };

    if descriptor.provider_type != expected_type {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::ExecutionTargetMismatch,
            message: format!(
                "Provider '{}' is '{}' but execution target requires '{}'.",
                descriptor.id,
                provider_type_name(&descriptor.provider_type),
                provider_type_name(&expected_type)
            ),
        });
    }

    if matches!(input.constraints.execution_target, ExecutionTarget::Cloud)
        && input.constraints.network_online == Some(false)
    {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::Offline,
            message: format!(
                "Provider '{}' requires cloud connectivity, but the host is offline.",
                descriptor.id
            ),
        });
    } else if !capabilities.available {
        reasons.push(RejectionReason {
            code: RejectionReasonCode::CapabilityUnavailable,
            message: capabilities
                .reason
                .clone()
                .unwrap_or_else(|| format!("Provider '{}' is currently unavailable.", descriptor.id)),
        });
    }

    reasons
}

fn provider_type_name(provider_type: &ProviderType) -> &'static str {
    match provider_type {
        ProviderType::Local => "local",
        ProviderType::Edge => "edge",
        ProviderType::Cloud => "cloud",
    }
}

fn infer_failure_code(constraints: &RoutingConstraints) -> RouteFailureCode {
    match constraints.execution_target {
        ExecutionTarget::OnDevice => RouteFailureCode::CapabilityMismatch,
        ExecutionTarget::Cloud if constraints.network_online == Some(false) => RouteFailureCode::Offline,
        ExecutionTarget::Cloud => RouteFailureCode::Unavailable,
    }
}

fn plan_route_json_string(input_json: &str) -> Result<String, String> {
    let input = serde_json::from_str::<PlanRouteInput>(input_json).map_err(|error| error.to_string())?;
    let output = plan_route(input);
    serde_json::to_string(&output).map_err(|error| error.to_string())
}

#[no_mangle]
pub extern "C" fn inderun_plan_route_json(input_json: *const c_char) -> *mut c_char {
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

#[no_mangle]
pub extern "C" fn inderun_free_string(value: *mut c_char) {
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

    fn local_provider(id: &str, available: bool) -> ProviderInput {
        ProviderInput {
            descriptor: ProviderDescriptor {
                id: id.to_string(),
                provider_type: ProviderType::Local,
                supports: ProviderRunSupport { run: true },
                tasks: vec!["text_to_text".to_string()],
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
            },
            capabilities: ProviderCapabilitySnapshot {
                available,
                reason: (!available).then(|| "Cloud runtime unavailable.".to_string()),
            },
        }
    }

    #[test]
    fn selects_available_on_device_provider_deterministically() {
        let plan = plan_route(PlanRouteInput {
            task: RoutingTask {
                kind: "text_to_text".to_string(),
            },
            constraints: RoutingConstraints {
                execution_target: ExecutionTarget::OnDevice,
                network_online: Some(true),
            },
            preferences: RoutingPreferences::default(),
            providers: vec![local_provider("provider_b", true), local_provider("provider_a", true)],
        });

        assert_eq!(plan.selected_provider_id.as_deref(), Some("provider_a"));
        assert_eq!(plan.fallback_provider_ids, vec!["provider_b".to_string()]);
        assert!(plan.failure_code.is_none());
    }

    #[test]
    fn rejects_unavailable_providers_with_reasons() {
        let plan = plan_route(PlanRouteInput {
            task: RoutingTask {
                kind: "text_to_text".to_string(),
            },
            constraints: RoutingConstraints {
                execution_target: ExecutionTarget::OnDevice,
                network_online: Some(true),
            },
            preferences: RoutingPreferences::default(),
            providers: vec![local_provider("provider_a", false)],
        });

        assert_eq!(plan.selected_provider_id, None);
        assert_eq!(plan.failure_code, Some(RouteFailureCode::CapabilityMismatch));
        assert_eq!(plan.rejected_providers.len(), 1);
        assert_eq!(
            plan.rejected_providers[0].reasons[0].code,
            RejectionReasonCode::CapabilityUnavailable
        );
    }

    #[test]
    fn returns_offline_failure_for_cloud_when_host_is_offline() {
        let plan = plan_route(PlanRouteInput {
            task: RoutingTask {
                kind: "text_to_text".to_string(),
            },
            constraints: RoutingConstraints {
                execution_target: ExecutionTarget::Cloud,
                network_online: Some(false),
            },
            preferences: RoutingPreferences::default(),
            providers: vec![cloud_provider("cloud_a", true)],
        });

        assert_eq!(plan.selected_provider_id, None);
        assert_eq!(plan.failure_code, Some(RouteFailureCode::Offline));
        assert_eq!(
            plan.rejected_providers[0].reasons[0].code,
            RejectionReasonCode::Offline
        );
    }

    #[test]
    fn preserves_fallback_order_after_selection() {
        let plan = plan_route(PlanRouteInput {
            task: RoutingTask {
                kind: "text_to_text".to_string(),
            },
            constraints: RoutingConstraints {
                execution_target: ExecutionTarget::Cloud,
                network_online: Some(true),
            },
            preferences: RoutingPreferences::default(),
            providers: vec![
                cloud_provider("cloud_b", true),
                cloud_provider("cloud_c", true),
                cloud_provider("cloud_a", true),
            ],
        });

        assert_eq!(plan.selected_provider_id.as_deref(), Some("cloud_a"));
        assert_eq!(
            plan.fallback_provider_ids,
            vec!["cloud_b".to_string(), "cloud_c".to_string()]
        );
    }
}
