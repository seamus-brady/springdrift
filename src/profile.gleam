//// Profile discovery, parsing, and validation.
////
//// Profiles are self-contained directories with config.toml, optional dprime.json,
//// optional schedule.toml, and optional skills/ subdirectory.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import profile/types.{
  type AgentDef, type DeliveryConfig, type Profile, type ProfileModels,
  type ScheduleTaskConfig, AgentDef, FileDelivery, Profile, ProfileModels,
  ScheduleTaskConfig, WebhookDelivery,
}
import simplifile
import slog
import tom

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "springdrift_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Default profile directories to scan.
pub fn default_profile_dirs() -> List(String) {
  case get_env("HOME") {
    Ok(home) -> [home <> "/.config/springdrift/profiles", "profiles"]
    Error(_) -> ["profiles"]
  }
}

/// Discover all valid profiles across the given directories.
pub fn discover(dirs: List(String)) -> List(String) {
  let names =
    list.flat_map(dirs, fn(dir) {
      case simplifile.read_directory(dir) {
        Error(_) -> []
        Ok(entries) ->
          list.filter(entries, fn(entry) {
            let config_path = dir <> "/" <> entry <> "/config.toml"
            case simplifile.is_file(config_path) {
              Ok(True) -> True
              _ -> False
            }
          })
      }
    })
    |> list.unique
  slog.info(
    "profile",
    "discover",
    "Found "
      <> int.to_string(list.length(names))
      <> " profiles: "
      <> string.join(names, ", "),
    None,
  )
  names
}

/// Load a profile by name from the given directories.
pub fn load(name: String, dirs: List(String)) -> Result(Profile, String) {
  case find_profile_dir(name, dirs) {
    Error(_) -> Error("Profile not found: " <> name)
    Ok(dir) -> parse_profile(name, dir)
  }
}

/// Parse a schedule.toml file into a list of scheduled task configs.
pub fn parse_schedule(path: String) -> Result(List(ScheduleTaskConfig), String) {
  case simplifile.read(path) {
    Error(_) -> Error("Could not read schedule file: " <> path)
    Ok(contents) ->
      case tom.parse(contents) {
        Error(_) -> Error("Could not parse schedule file: " <> path)
        Ok(toml) -> Ok(parse_schedule_tasks(toml))
      }
  }
}

// ---------------------------------------------------------------------------
// Internal — profile discovery
// ---------------------------------------------------------------------------

fn find_profile_dir(name: String, dirs: List(String)) -> Result(String, Nil) {
  case dirs {
    [] -> Error(Nil)
    [dir, ..rest] -> {
      let path = dir <> "/" <> name
      case simplifile.is_file(path <> "/config.toml") {
        Ok(True) -> Ok(path)
        _ -> find_profile_dir(name, rest)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Internal — profile parsing
// ---------------------------------------------------------------------------

fn parse_profile(name: String, dir: String) -> Result(Profile, String) {
  let config_path = dir <> "/config.toml"
  case simplifile.read(config_path) {
    Error(_) -> Error("Could not read profile config: " <> config_path)
    Ok(contents) ->
      case tom.parse(contents) {
        Error(_) -> Error("Could not parse profile config: " <> config_path)
        Ok(toml) -> {
          let description = case
            tom.get_string(toml, ["profile", "description"])
          {
            Ok(d) -> d
            Error(_) -> name <> " profile"
          }
          let models = parse_models(toml)
          let agents = parse_agents(toml)

          let dprime_path = case simplifile.is_file(dir <> "/dprime.json") {
            Ok(True) -> Some(dir <> "/dprime.json")
            _ -> None
          }

          let schedule_path = case simplifile.is_file(dir <> "/schedule.toml") {
            Ok(True) -> Some(dir <> "/schedule.toml")
            _ -> None
          }

          let skills_dir = case simplifile.is_directory(dir <> "/skills") {
            Ok(True) -> Some(dir <> "/skills")
            _ -> None
          }

          slog.info(
            "profile",
            "parse_profile",
            "Loaded profile '"
              <> name
              <> "' with "
              <> int.to_string(list.length(agents))
              <> " agents",
            None,
          )

          Ok(Profile(
            name:,
            description:,
            dir:,
            models:,
            agents:,
            dprime_path:,
            schedule_path:,
            skills_dir:,
          ))
        }
      }
  }
}

fn parse_models(toml: dict.Dict(String, tom.Toml)) -> ProfileModels {
  ProfileModels(
    task_model: case tom.get_string(toml, ["models", "task_model"]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
    reasoning_model: case tom.get_string(toml, ["models", "reasoning_model"]) {
      Ok(v) -> Some(v)
      Error(_) -> None
    },
  )
}

fn parse_agents(toml: dict.Dict(String, tom.Toml)) -> List(AgentDef) {
  case tom.get_array(toml, ["agents"]) {
    Error(_) -> []
    Ok(items) -> list.filter_map(items, parse_agent_item)
  }
}

fn parse_agent_item(item: tom.Toml) -> Result(AgentDef, Nil) {
  case item {
    tom.InlineTable(table) | tom.Table(table) ->
      case dict.get(table, "name") {
        Ok(tom.String(name)) -> {
          let description = case dict.get(table, "description") {
            Ok(tom.String(d)) -> d
            _ -> name <> " agent"
          }
          let tools = case dict.get(table, "tools") {
            Ok(tom.Array(items)) ->
              list.filter_map(items, fn(t) {
                case t {
                  tom.String(s) -> Ok(s)
                  _ -> Error(Nil)
                }
              })
            _ -> []
          }
          let max_turns = case dict.get(table, "max_turns") {
            Ok(tom.Int(n)) -> n
            _ -> 5
          }
          let system_prompt = case dict.get(table, "system_prompt") {
            Ok(tom.String(s)) -> Some(s)
            _ -> None
          }
          Ok(AgentDef(name:, description:, tools:, max_turns:, system_prompt:))
        }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Internal — schedule parsing
// ---------------------------------------------------------------------------

fn parse_schedule_tasks(
  toml: dict.Dict(String, tom.Toml),
) -> List(ScheduleTaskConfig) {
  case tom.get_array(toml, ["tasks"]) {
    Error(_) -> []
    Ok(items) -> list.filter_map(items, parse_schedule_item(toml, _))
  }
}

fn parse_schedule_item(
  root_toml: dict.Dict(String, tom.Toml),
  item: tom.Toml,
) -> Result(ScheduleTaskConfig, Nil) {
  case item {
    tom.InlineTable(table) | tom.Table(table) ->
      case dict.get(table, "name"), dict.get(table, "query") {
        Ok(tom.String(name)), Ok(tom.String(query)) -> {
          let interval_ms = case dict.get(table, "interval") {
            Ok(tom.String(s)) -> parse_interval(s)
            _ -> 86_400_000
          }
          let start_at = case dict.get(table, "start_at") {
            Ok(tom.String(s)) -> Some(s)
            _ -> None
          }
          let only_if_changed = case dict.get(table, "only_if_changed") {
            Ok(tom.Bool(b)) -> b
            _ -> False
          }
          let delivery_channel = case dict.get(table, "delivery") {
            Ok(tom.String(s)) -> s
            _ -> "file"
          }
          let delivery = parse_delivery(root_toml, delivery_channel)
          Ok(ScheduleTaskConfig(
            name:,
            query:,
            interval_ms:,
            start_at:,
            delivery:,
            only_if_changed:,
          ))
        }
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Parse interval strings like "24h", "6h", "30m", "1d" into milliseconds.
pub fn parse_interval(s: String) -> Int {
  let trimmed = string.trim(s)
  let len = string.length(trimmed)
  case len > 1 {
    False -> 86_400_000
    True -> {
      let unit = string.slice(trimmed, len - 1, 1)
      let num_str = string.slice(trimmed, 0, len - 1)
      case int.parse(num_str) {
        Error(_) -> 86_400_000
        Ok(n) ->
          case unit {
            "s" -> n * 1000
            "m" -> n * 60 * 1000
            "h" -> n * 60 * 60 * 1000
            "d" -> n * 24 * 60 * 60 * 1000
            _ -> 86_400_000
          }
      }
    }
  }
}

fn parse_delivery(
  toml: dict.Dict(String, tom.Toml),
  channel: String,
) -> DeliveryConfig {
  case channel {
    "webhook" -> {
      let url = case tom.get_string(toml, ["delivery", "webhook", "url"]) {
        Ok(u) -> u
        Error(_) -> ""
      }
      let method = case
        tom.get_string(toml, ["delivery", "webhook", "method"])
      {
        Ok(m) -> m
        Error(_) -> "POST"
      }
      WebhookDelivery(url:, method:, headers: [])
    }
    _ -> {
      let directory = case
        tom.get_string(toml, ["delivery", "file", "directory"])
      {
        Ok(d) -> d
        Error(_) -> "./reports"
      }
      let format = case tom.get_string(toml, ["delivery", "file", "format"]) {
        Ok(f) -> f
        Error(_) -> "markdown"
      }
      FileDelivery(directory:, format:)
    }
  }
}
