//// Plan-health feature definitions for the Forecaster.
////
//// These features measure plan execution health and are scored by the
//// D' engine. When the composite D' score exceeds the replan threshold,
//// the Forecaster suggests replanning.

import dprime/types as dprime_types
import gleam/option.{None}

/// Plan-health features — single tier, scaling_unit = 9.
pub fn plan_health_features() -> List(dprime_types.Feature) {
  [
    dprime_types.Feature(
      name: "step_completion_rate",
      description: "Are steps finishing at expected velocity?",
      importance: dprime_types.High,
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "dependency_health",
      description: "Are there blocked dependencies?",
      importance: dprime_types.High,
      critical: True,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "complexity_drift",
      description: "Has observed complexity exceeded planned complexity?",
      importance: dprime_types.Medium,
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "risk_materialization",
      description: "Have predicted risks come true?",
      importance: dprime_types.Medium,
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
    dprime_types.Feature(
      name: "scope_creep",
      description: "Are unexpected steps accumulating?",
      importance: dprime_types.Low,
      critical: False,
      feature_set: None,
      feature_set_importance: None,
      group: None,
      group_importance: None,
    ),
  ]
}

/// Default replan threshold — D' score above this triggers a replan suggestion.
pub const default_replan_threshold = 0.55

/// Scaling unit for single-tier features.
pub const scaling_unit = 9
