import dprime/config as dprime_config
import gleam/list
import gleeunit
import gleeunit/should
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// default
// ---------------------------------------------------------------------------

pub fn default_has_five_features_test() {
  let cfg = dprime_config.default()
  list.length(cfg.features) |> should.equal(5)
}

pub fn default_has_expected_thresholds_test() {
  let cfg = dprime_config.default()
  cfg.modify_threshold |> should.equal(0.3)
  cfg.reject_threshold |> should.equal(0.7)
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
  list.length(critical) |> should.equal(2)
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
  // Defaults for omitted fields
  cfg.tiers |> should.equal(1)
  cfg.modify_threshold |> should.equal(0.3)
  cfg.reject_threshold |> should.equal(0.7)
  cfg.canary_enabled |> should.be_true
  let _ = simplifile.delete(path)
}
