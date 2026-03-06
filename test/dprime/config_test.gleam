import dprime/config as dprime_config
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// default
// ---------------------------------------------------------------------------

pub fn default_has_seven_features_test() {
  let cfg = dprime_config.default()
  list.length(cfg.features) |> should.equal(7)
}

pub fn default_has_expected_thresholds_test() {
  let cfg = dprime_config.default()
  cfg.modify_threshold |> should.equal(1.2)
  cfg.reject_threshold |> should.equal(2.0)
  cfg.reactive_reject_threshold |> should.equal(0.8)
}

pub fn default_tiers_is_one_test() {
  let cfg = dprime_config.default()
  cfg.tiers |> should.equal(1)
}

pub fn default_canary_enabled_test() {
  let cfg = dprime_config.default()
  cfg.canary_enabled |> should.be_true
}

pub fn default_has_critical_features_test() {
  let cfg = dprime_config.default()
  let critical = list.filter(cfg.features, fn(f) { f.critical })
  // user_safety, accuracy, legal_compliance are critical
  list.length(critical) |> should.equal(3)
}

pub fn default_has_agent_id_test() {
  let cfg = dprime_config.default()
  cfg.agent_id |> should.equal("general-assistant-v1")
}

pub fn default_has_threshold_floors_test() {
  let cfg = dprime_config.default()
  cfg.min_modify_threshold |> should.equal(0.8)
  cfg.min_reject_threshold |> should.equal(1.5)
}

pub fn default_adaptation_disabled_test() {
  let cfg = dprime_config.default()
  cfg.allow_adaptation |> should.be_false
}

pub fn default_control_loop_settings_test() {
  let cfg = dprime_config.default()
  cfg.max_iterations |> should.equal(3)
  cfg.max_candidates |> should.equal(3)
}

// ---------------------------------------------------------------------------
// initial_state
// ---------------------------------------------------------------------------

pub fn initial_state_has_empty_history_test() {
  let cfg = dprime_config.default()
  let state = dprime_config.initial_state(cfg)
  state.history |> should.equal([])
}

pub fn initial_state_thresholds_match_config_test() {
  let cfg = dprime_config.default()
  let state = dprime_config.initial_state(cfg)
  state.current_modify_threshold |> should.equal(cfg.modify_threshold)
  state.current_reject_threshold |> should.equal(cfg.reject_threshold)
}

pub fn initial_state_iteration_count_zero_test() {
  let cfg = dprime_config.default()
  let state = dprime_config.initial_state(cfg)
  state.iteration_count |> should.equal(0)
}

// ---------------------------------------------------------------------------
// load — JSON file
// ---------------------------------------------------------------------------

pub fn load_valid_json_test() {
  let json =
    "{
  \"features\": [
    {\"name\": \"test_safety\", \"importance\": \"high\", \"description\": \"Test\", \"critical\": true}
  ],
  \"tiers\": 2,
  \"modify_threshold\": 0.2,
  \"reject_threshold\": 0.6
}"
  let path = "/tmp/dprime_test_config.json"
  let assert Ok(_) = simplifile.write(path, json)
  let cfg = dprime_config.load(path)
  list.length(cfg.features) |> should.equal(1)
  cfg.tiers |> should.equal(2)
  cfg.modify_threshold |> should.equal(0.2)
  cfg.reject_threshold |> should.equal(0.6)
  let _ = simplifile.delete(path)
}

pub fn load_missing_file_returns_default_test() {
  let cfg = dprime_config.load("/tmp/nonexistent_dprime_config.json")
  cfg |> should.equal(dprime_config.default())
}

pub fn load_invalid_json_returns_default_test() {
  let path = "/tmp/dprime_test_invalid.json"
  let assert Ok(_) = simplifile.write(path, "not valid json {{{")
  let cfg = dprime_config.load(path)
  cfg |> should.equal(dprime_config.default())
  let _ = simplifile.delete(path)
}

pub fn load_partial_json_uses_defaults_for_missing_fields_test() {
  let json =
    "{
  \"features\": [
    {\"name\": \"only_one\", \"importance\": \"low\"}
  ]
}"
  let path = "/tmp/dprime_test_partial.json"
  let assert Ok(_) = simplifile.write(path, json)
  let cfg = dprime_config.load(path)
  list.length(cfg.features) |> should.equal(1)
  cfg.tiers |> should.equal(1)
  cfg.modify_threshold |> should.equal(1.2)
  cfg.reject_threshold |> should.equal(2.0)
  cfg.canary_enabled |> should.be_true
  let _ = simplifile.delete(path)
}

pub fn load_full_schema_test() {
  let json =
    "{
  \"agent_id\": \"test-agent-v1\",
  \"features\": [
    {\"name\": \"safety\", \"importance\": \"high\", \"critical\": true,
     \"feature_set\": \"core\", \"feature_set_importance\": \"medium\"}
  ],
  \"tiers\": 2,
  \"modify_threshold\": 1.0,
  \"reject_threshold\": 1.8,
  \"reactive_reject_threshold\": 0.6,
  \"min_modify_threshold\": 0.5,
  \"min_reject_threshold\": 1.0,
  \"allow_adaptation\": true,
  \"max_iterations\": 5,
  \"max_candidates\": 2
}"
  let path = "/tmp/dprime_test_full.json"
  let assert Ok(_) = simplifile.write(path, json)
  let cfg = dprime_config.load(path)
  cfg.agent_id |> should.equal("test-agent-v1")
  cfg.tiers |> should.equal(2)
  cfg.reactive_reject_threshold |> should.equal(0.6)
  cfg.min_modify_threshold |> should.equal(0.5)
  cfg.allow_adaptation |> should.be_true
  cfg.max_iterations |> should.equal(5)
  cfg.max_candidates |> should.equal(2)
  let assert [f] = cfg.features
  f.feature_set |> should.equal(Some("core"))
  let _ = simplifile.delete(path)
}
