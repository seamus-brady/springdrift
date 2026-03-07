//// Profile system types — switchable agent team configurations.

import gleam/option.{type Option}

/// A loaded profile describing an agent team, models, D' config, and schedule.
pub type Profile {
  Profile(
    name: String,
    description: String,
    dir: String,
    models: ProfileModels,
    agents: List(AgentDef),
    dprime_path: Option(String),
    schedule_path: Option(String),
    skills_dir: Option(String),
  )
}

/// Model overrides for a profile. None means use global defaults.
pub type ProfileModels {
  ProfileModels(task_model: Option(String), reasoning_model: Option(String))
}

/// An agent definition from a profile's config.toml.
pub type AgentDef {
  AgentDef(
    name: String,
    description: String,
    tools: List(String),
    max_turns: Int,
    system_prompt: Option(String),
  )
}

/// Delivery configuration for scheduled tasks.
pub type DeliveryConfig {
  FileDelivery(directory: String, format: String)
  WebhookDelivery(url: String, method: String, headers: List(#(String, String)))
}

/// A scheduled task definition from schedule.toml.
pub type ScheduleTaskConfig {
  ScheduleTaskConfig(
    name: String,
    query: String,
    interval_ms: Int,
    start_at: Option(String),
    delivery: DeliveryConfig,
    only_if_changed: Bool,
  )
}
