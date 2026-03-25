import dprime/config as dprime_config
import dprime/deterministic.{BlockAction, EscalateAction}
import dprime/types as dprime_types
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import meta/types as meta_types
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
  cfg.modify_threshold |> should.equal(0.35)
  cfg.reject_threshold |> should.equal(0.55)
  cfg.reactive_reject_threshold |> should.equal(0.65)
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
  cfg.min_modify_threshold |> should.equal(0.2)
  cfg.min_reject_threshold |> should.equal(0.4)
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
  cfg.modify_threshold |> should.equal(0.35)
  cfg.reject_threshold |> should.equal(0.55)
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

// ---------------------------------------------------------------------------
// load_dual — dual-gate config
// ---------------------------------------------------------------------------

pub fn load_dual_with_both_gates_test() {
  let json =
    "{
  \"tool_gate\": {
    \"features\": [
      {\"name\": \"fs_write\", \"importance\": \"medium\"}
    ],
    \"modify_threshold\": 0.4,
    \"reject_threshold\": 0.7,
    \"canary_enabled\": false
  },
  \"output_gate\": {
    \"features\": [
      {\"name\": \"unsourced_claim\", \"importance\": \"high\", \"critical\": true},
      {\"name\": \"stale_data\", \"importance\": \"medium\"}
    ],
    \"modify_threshold\": 0.3,
    \"reject_threshold\": 0.6
  }
}"
  let path = "/tmp/dprime_test_dual.json"
  let assert Ok(_) = simplifile.write(path, json)
  let #(tool_cfg, output_cfg) = dprime_config.load_dual(path)

  // Tool gate
  list.length(tool_cfg.features) |> should.equal(1)
  tool_cfg.modify_threshold |> should.equal(0.4)
  tool_cfg.canary_enabled |> should.be_false

  // Output gate
  output_cfg |> should.not_equal(None)
  let assert Some(out) = output_cfg
  list.length(out.features) |> should.equal(2)
  out.modify_threshold |> should.equal(0.3)
  out.reject_threshold |> should.equal(0.6)

  let _ = simplifile.delete(path)
}

pub fn load_dual_single_gate_fallback_test() {
  let json =
    "{
  \"features\": [
    {\"name\": \"safety\", \"importance\": \"high\", \"critical\": true}
  ],
  \"tiers\": 2
}"
  let path = "/tmp/dprime_test_dual_single.json"
  let assert Ok(_) = simplifile.write(path, json)
  let #(tool_cfg, output_cfg) = dprime_config.load_dual(path)
  list.length(tool_cfg.features) |> should.equal(1)
  tool_cfg.tiers |> should.equal(2)
  output_cfg |> should.equal(None)
  let _ = simplifile.delete(path)
}

pub fn load_dual_missing_file_test() {
  let #(tool_cfg, output_cfg) =
    dprime_config.load_dual("/tmp/nonexistent_dual.json")
  tool_cfg |> should.equal(dprime_config.default())
  output_cfg |> should.equal(None)
}

// ---------------------------------------------------------------------------
// default_unified
// ---------------------------------------------------------------------------

pub fn default_unified_has_default_gates_test() {
  let u = dprime_config.default_unified()
  u.input_gate |> should.equal(dprime_config.default())
  u.tool_gate |> should.equal(dprime_config.default())
  u.output_gate |> should.equal(None)
  u.post_exec_gate |> should.equal(None)
  u.agent_overrides |> should.equal([])
  u.meta |> should.equal(None)
}

// ---------------------------------------------------------------------------
// get_agent_tool_config
// ---------------------------------------------------------------------------

pub fn get_agent_tool_config_no_override_test() {
  let u = dprime_config.default_unified()
  let cfg = dprime_config.get_agent_tool_config(u, "researcher")
  cfg |> should.equal(u.tool_gate)
}

pub fn get_agent_tool_config_with_override_test() {
  let custom_gate =
    dprime_types.DprimeConfig(
      ..dprime_config.default(),
      modify_threshold: 0.1,
      reject_threshold: 0.2,
    )
  let override =
    dprime_config.AgentDprimeOverride(
      agent_name: "researcher",
      tool_gate: Some(custom_gate),
    )
  let u =
    dprime_config.UnifiedDprimeConfig(
      ..dprime_config.default_unified(),
      agent_overrides: [override],
    )
  let cfg = dprime_config.get_agent_tool_config(u, "researcher")
  cfg |> should.equal(custom_gate)
}

pub fn get_agent_tool_config_override_with_none_falls_back_test() {
  let override =
    dprime_config.AgentDprimeOverride(agent_name: "researcher", tool_gate: None)
  let u =
    dprime_config.UnifiedDprimeConfig(
      ..dprime_config.default_unified(),
      agent_overrides: [override],
    )
  let cfg = dprime_config.get_agent_tool_config(u, "researcher")
  cfg |> should.equal(u.tool_gate)
}

// ---------------------------------------------------------------------------
// load_unified — new unified format
// ---------------------------------------------------------------------------

pub fn load_unified_with_gates_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [
        {\"name\": \"input_safety\", \"importance\": \"high\", \"critical\": true}
      ],
      \"modify_threshold\": 0.3
    },
    \"tool\": {
      \"features\": [
        {\"name\": \"fs_write\", \"importance\": \"medium\"}
      ],
      \"modify_threshold\": 0.4,
      \"reject_threshold\": 0.7
    }
  }
}"
  let path = "/tmp/dprime_test_unified.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  list.length(u.input_gate.features) |> should.equal(1)
  u.input_gate.modify_threshold |> should.equal(0.3)
  list.length(u.tool_gate.features) |> should.equal(1)
  u.tool_gate.modify_threshold |> should.equal(0.4)
  u.tool_gate.reject_threshold |> should.equal(0.7)
  u.output_gate |> should.equal(None)
  u.post_exec_gate |> should.equal(None)
  u.agent_overrides |> should.equal([])
  u.meta |> should.equal(None)
  let _ = simplifile.delete(path)
}

pub fn load_unified_with_output_gate_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"tool\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"output\": {
      \"features\": [{\"name\": \"quality\", \"importance\": \"medium\"}],
      \"modify_threshold\": 0.25
    }
  }
}"
  let path = "/tmp/dprime_test_unified_output.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  let assert Some(out) = u.output_gate
  list.length(out.features) |> should.equal(1)
  out.modify_threshold |> should.equal(0.25)
  let _ = simplifile.delete(path)
}

pub fn load_unified_with_agent_overrides_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"tool\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    }
  },
  \"agent_overrides\": [
    {
      \"agent_name\": \"researcher\",
      \"tool\": {
        \"features\": [{\"name\": \"web_access\", \"importance\": \"low\"}],
        \"reject_threshold\": 0.9
      }
    }
  ]
}"
  let path = "/tmp/dprime_test_unified_overrides.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  list.length(u.agent_overrides) |> should.equal(1)
  let assert [override] = u.agent_overrides
  override.agent_name |> should.equal("researcher")
  let assert Some(tool_cfg) = override.tool_gate
  tool_cfg.reject_threshold |> should.equal(0.9)
  let _ = simplifile.delete(path)
}

pub fn load_unified_with_meta_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"tool\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    }
  },
  \"meta\": {
    \"enabled\": true,
    \"cooldown_delay_ms\": 10000,
    \"tighten_factor\": 0.8
  }
}"
  let path = "/tmp/dprime_test_unified_meta.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  let assert Some(meta) = u.meta
  meta.enabled |> should.be_true
  meta.cooldown_delay_ms |> should.equal(10_000)
  meta.tighten_factor |> should.equal(0.8)
  // Other fields should get defaults
  meta.max_history |> should.equal(meta_types.default_config().max_history)
  let _ = simplifile.delete(path)
}

pub fn load_unified_with_shared_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"tool\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}],
      \"tiers\": 3
    }
  },
  \"shared\": {
    \"tiers\": 2,
    \"max_iterations\": 5
  }
}"
  let path = "/tmp/dprime_test_unified_shared.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  // input_gate should get shared tiers=2 (had default 1)
  u.input_gate.tiers |> should.equal(2)
  u.input_gate.max_iterations |> should.equal(5)
  // tool_gate explicitly set tiers=3, so shared should not override
  u.tool_gate.tiers |> should.equal(3)
  u.tool_gate.max_iterations |> should.equal(5)
  let _ = simplifile.delete(path)
}

pub fn load_unified_falls_back_to_dual_format_test() {
  let json =
    "{
  \"tool_gate\": {
    \"features\": [{\"name\": \"fs_write\", \"importance\": \"medium\"}],
    \"modify_threshold\": 0.4
  },
  \"output_gate\": {
    \"features\": [{\"name\": \"quality\", \"importance\": \"high\"}]
  }
}"
  let path = "/tmp/dprime_test_unified_dual_fallback.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  // Dual format uses tool_gate for both input and tool
  u.input_gate.modify_threshold |> should.equal(0.4)
  u.tool_gate.modify_threshold |> should.equal(0.4)
  let assert Some(_) = u.output_gate
  u.agent_overrides |> should.equal([])
  let _ = simplifile.delete(path)
}

pub fn load_unified_falls_back_to_single_format_test() {
  let json =
    "{
  \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}],
  \"reject_threshold\": 0.8
}"
  let path = "/tmp/dprime_test_unified_single_fallback.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  u.input_gate.reject_threshold |> should.equal(0.8)
  u.tool_gate.reject_threshold |> should.equal(0.8)
  u.output_gate |> should.equal(None)
  let _ = simplifile.delete(path)
}

pub fn load_unified_missing_file_returns_defaults_test() {
  let u = dprime_config.load_unified("/tmp/nonexistent_unified.json")
  u |> should.equal(dprime_config.default_unified())
}

pub fn load_unified_invalid_json_returns_defaults_test() {
  let path = "/tmp/dprime_test_unified_invalid.json"
  let assert Ok(_) = simplifile.write(path, "not valid {{{")
  let u = dprime_config.load_unified(path)
  u |> should.equal(dprime_config.default_unified())
  let _ = simplifile.delete(path)
}

// ---------------------------------------------------------------------------
// Deterministic config in unified format
// ---------------------------------------------------------------------------

pub fn load_unified_with_deterministic_section_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"tool\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    }
  },
  \"deterministic\": {
    \"enabled\": true,
    \"input_rules\": [
      {\"id\": \"injection-override\", \"pattern\": \"ignore previous instructions\", \"action\": \"block\"}
    ],
    \"tool_rules\": [
      {\"id\": \"rm-rf\", \"pattern\": \"rm\\\\s+-rf\\\\s+/\", \"action\": \"block\"}
    ],
    \"output_rules\": [
      {\"id\": \"credential-leak\", \"pattern\": \"sk-[A-Za-z0-9_-]{20,}\", \"action\": \"block\"}
    ],
    \"path_allowlist\": [\"/home/user/projects\"],
    \"domain_allowlist\": [\"example.com\", \"api.openai.com\"]
  }
}"
  let path = "/tmp/dprime_test_unified_deterministic.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  u.deterministic.enabled |> should.be_true
  list.length(u.deterministic.input_rules) |> should.equal(1)
  list.length(u.deterministic.tool_rules) |> should.equal(1)
  list.length(u.deterministic.output_rules) |> should.equal(1)
  list.length(u.deterministic.path_allowlist) |> should.equal(1)
  list.length(u.deterministic.domain_allowlist) |> should.equal(2)
  // Verify rule details
  let assert [input_rule] = u.deterministic.input_rules
  input_rule.id |> should.equal("injection-override")
  input_rule.action |> should.equal(BlockAction)
  let assert [tool_rule] = u.deterministic.tool_rules
  tool_rule.id |> should.equal("rm-rf")
  tool_rule.action |> should.equal(BlockAction)
  let _ = simplifile.delete(path)
}

pub fn load_unified_missing_deterministic_defaults_to_empty_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"tool\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    }
  }
}"
  let path = "/tmp/dprime_test_unified_no_deterministic.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  u.deterministic |> should.equal(deterministic.default_config())
  u.deterministic.enabled |> should.be_true
  u.deterministic.input_rules |> should.equal([])
  u.deterministic.tool_rules |> should.equal([])
  u.deterministic.output_rules |> should.equal([])
  u.deterministic.path_allowlist |> should.equal([])
  u.deterministic.domain_allowlist |> should.equal([])
  let _ = simplifile.delete(path)
}

pub fn load_unified_deterministic_with_escalate_action_test() {
  let json =
    "{
  \"gates\": {
    \"input\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    },
    \"tool\": {
      \"features\": [{\"name\": \"safety\", \"importance\": \"high\"}]
    }
  },
  \"deterministic\": {
    \"enabled\": true,
    \"input_rules\": [
      {\"id\": \"suspicious\", \"pattern\": \"you are now\", \"action\": \"escalate\"}
    ]
  }
}"
  let path = "/tmp/dprime_test_unified_det_escalate.json"
  let assert Ok(_) = simplifile.write(path, json)
  let u = dprime_config.load_unified(path)
  let assert [rule] = u.deterministic.input_rules
  rule.action |> should.equal(EscalateAction)
  let _ = simplifile.delete(path)
}
