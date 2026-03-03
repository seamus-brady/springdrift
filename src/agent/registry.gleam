import agent/types.{type AgentTask}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type AgentStatus {
  Running
  Restarting
  Stopped
}

pub type RegistryEntry {
  RegistryEntry(
    name: String,
    task_subject: Subject(AgentTask),
    status: AgentStatus,
  )
}

pub opaque type Registry {
  Registry(entries: List(RegistryEntry))
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn new() -> Registry {
  Registry(entries: [])
}

pub fn register(
  registry: Registry,
  name: String,
  task_subject: Subject(AgentTask),
) -> Registry {
  case list.find(registry.entries, fn(e) { e.name == name }) {
    Ok(_) -> update_task_subject(registry, name, task_subject)
    Error(_) -> {
      let entry = RegistryEntry(name:, task_subject:, status: Running)
      Registry(entries: list.append(registry.entries, [entry]))
    }
  }
}

pub fn update_task_subject(
  registry: Registry,
  name: String,
  new_subject: Subject(AgentTask),
) -> Registry {
  Registry(
    entries: list.map(registry.entries, fn(e) {
      case e.name == name {
        True -> RegistryEntry(..e, task_subject: new_subject, status: Running)
        False -> e
      }
    }),
  )
}

pub fn unregister(registry: Registry, name: String) -> Registry {
  Registry(entries: list.filter(registry.entries, fn(e) { e.name != name }))
}

pub fn get_task_subject(
  registry: Registry,
  name: String,
) -> Option(Subject(AgentTask)) {
  case list.find(registry.entries, fn(e) { e.name == name }) {
    Ok(entry) -> Some(entry.task_subject)
    Error(_) -> None
  }
}

pub fn get_status(registry: Registry, name: String) -> Option(AgentStatus) {
  case list.find(registry.entries, fn(e) { e.name == name }) {
    Ok(entry) -> Some(entry.status)
    Error(_) -> None
  }
}

pub fn mark_running(registry: Registry, name: String) -> Registry {
  update_status(registry, name, Running)
}

pub fn mark_restarting(registry: Registry, name: String) -> Registry {
  update_status(registry, name, Restarting)
}

pub fn mark_stopped(registry: Registry, name: String) -> Registry {
  update_status(registry, name, Stopped)
}

pub fn list_agents(registry: Registry) -> List(RegistryEntry) {
  registry.entries
}

pub fn size(registry: Registry) -> Int {
  list.length(registry.entries)
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn update_status(
  registry: Registry,
  name: String,
  status: AgentStatus,
) -> Registry {
  Registry(
    entries: list.map(registry.entries, fn(e) {
      case e.name == name {
        True -> RegistryEntry(..e, status:)
        False -> e
      }
    }),
  )
}
