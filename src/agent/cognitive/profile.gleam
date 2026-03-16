import agent/cognitive_state.{
  type CognitiveState, CognitiveState, IdentityContext,
}
import agent/types.{type CognitiveReply, CognitiveReply}
import dprime/config as dprime_config_mod
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import llm/provider.{type Provider}
import llm/types as llm_types
import profile
import profile/types as profile_types
import skills
import slog
import tools/builtin
import tools/web as tools_web

/// Handle a LoadProfile message — load and apply a named profile.
pub fn handle_load_profile(
  state: CognitiveState,
  name: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  case state.status {
    types.Idle -> do_load_profile(state, name, reply_to)
    _ -> {
      // Not idle — reject
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Cannot switch profiles while busy. Try again when idle.]",
          model: state.model,
          usage: None,
        ),
      )
      state
    }
  }
}

fn do_load_profile(
  state: CognitiveState,
  name: String,
  reply_to: Subject(CognitiveReply),
) -> CognitiveState {
  case profile.load(name, state.identity.profile_dirs) {
    Error(msg) -> {
      slog.warn("cognitive", "do_load_profile", msg, state.cycle_id)
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Profile error: " <> msg <> "]",
          model: state.model,
          usage: None,
        ),
      )
      state
    }
    Ok(loaded_profile) -> {
      slog.info(
        "cognitive",
        "do_load_profile",
        "Loading profile: " <> name,
        state.cycle_id,
      )

      // Shutdown existing agents if we have a supervisor reference
      case state.supervisor {
        Some(sup) -> process.send(sup, types.ShutdownAll)
        None -> Nil
      }

      // Build new agent specs from profile
      let task_model = case loaded_profile.models.task_model {
        Some(m) -> m
        None -> state.task_model
      }
      let reasoning_model = case loaded_profile.models.reasoning_model {
        Some(m) -> m
        None -> state.reasoning_model
      }

      let agent_specs =
        profile_agent_specs(
          loaded_profile,
          state.provider,
          task_model,
          state.identity.write_anywhere,
        )
      let agent_tools = list.map(agent_specs, types.agent_to_tool)
      let tools = [builtin.human_input_tool(), ..agent_tools]

      // Load profile-specific D' config (dual-gate: tool_gate + output_gate)
      let #(dprime_state, output_dprime_state) = case
        loaded_profile.dprime_path
      {
        Some(path) -> {
          let #(tool_cfg, output_cfg) = dprime_config_mod.load_dual(path)
          let tool_state = Some(dprime_config_mod.initial_state(tool_cfg))
          let output_state = case output_cfg {
            Some(cfg) -> Some(dprime_config_mod.initial_state(cfg))
            None -> None
          }
          #(tool_state, output_state)
        }
        None -> #(state.dprime_state, state.output_dprime_state)
      }

      // Load profile-specific skills
      let skill_dirs = case loaded_profile.skills_dir {
        Some(sd) -> [sd]
        None -> []
      }
      let discovered = skills.discover(skill_dirs)
      let base_system =
        "You are a cognitive orchestrator. You manage specialist agents and talk to the human. Use agent tools to delegate work and request_human_input to ask questions."
      let system = case discovered {
        [] -> base_system
        _ -> base_system <> "\n\n" <> skills.to_system_prompt_xml(discovered)
      }

      // Start new agents via supervisor
      case state.supervisor {
        Some(sup) ->
          list.each(agent_specs, fn(spec) {
            let rs = process.new_subject()
            process.send(sup, types.StartChild(spec:, reply_to: rs))
            case process.receive(rs, 5000) {
              Ok(Ok(_)) ->
                slog.info(
                  "cognitive",
                  "do_load_profile",
                  "Started agent: " <> spec.name,
                  state.cycle_id,
                )
              _ ->
                slog.warn(
                  "cognitive",
                  "do_load_profile",
                  "Failed to start agent: " <> spec.name,
                  state.cycle_id,
                )
            }
          })
        None -> Nil
      }

      // Notify UI
      process.send(state.notify, types.ProfileNotification(name:))

      let agent_names =
        list.map(agent_specs, fn(s) { s.name })
        |> string.join(", ")
      process.send(
        reply_to,
        CognitiveReply(
          response: "[Profile switched to '"
            <> name
            <> "' — agents: "
            <> agent_names
            <> "]",
          model: state.model,
          usage: None,
        ),
      )

      CognitiveState(
        ..state,
        tools:,
        system:,
        model: task_model,
        task_model:,
        reasoning_model:,
        messages: [],
        dprime_state:,
        output_dprime_state:,
        identity: IdentityContext(..state.identity, active_profile: Some(name)),
      )
    }
  }
}

fn profile_agent_specs(
  p: profile_types.Profile,
  provider: Provider,
  task_model: String,
  write_anywhere: Bool,
) -> List(types.AgentSpec) {
  list.map(p.agents, fn(agent_def) {
    let tools_list = resolve_agent_tools(agent_def.tools)
    let model = task_model
    let system_prompt = case agent_def.system_prompt {
      Some(sp) -> sp
      None ->
        "You are a " <> agent_def.name <> " agent. " <> agent_def.description
    }
    let tool_executor = build_tool_executor(agent_def.tools, write_anywhere)
    types.AgentSpec(
      name: agent_def.name,
      human_name: string.capitalise(agent_def.name),
      description: agent_def.description,
      system_prompt:,
      provider:,
      model:,
      max_tokens: 4096,
      max_turns: agent_def.max_turns,
      max_consecutive_errors: 3,
      max_context_messages: option.None,
      tools: tools_list,
      restart: types.Permanent,
      tool_executor:,
      inter_turn_delay_ms: 200,
    )
  })
}

fn resolve_agent_tools(tool_groups: List(String)) -> List(llm_types.Tool) {
  list.flat_map(tool_groups, fn(group) {
    case group {
      "web" -> tools_web.all()
      "builtin" -> builtin.all()
      _ -> []
    }
  })
}

fn build_tool_executor(
  tool_groups: List(String),
  _write_anywhere: Bool,
) -> fn(llm_types.ToolCall) -> llm_types.ToolResult {
  let has_web = list.contains(tool_groups, "web")
  fn(call: llm_types.ToolCall) -> llm_types.ToolResult {
    case has_web && tools_web.is_web_tool(call.name) {
      True -> tools_web.execute(call)
      False -> builtin.execute(call)
    }
  }
}
