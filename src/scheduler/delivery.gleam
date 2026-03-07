//// Scheduler delivery — write finished reports to configured destinations.

import gleam/option.{None}
import gleam/string
import profile/types.{
  type DeliveryConfig, FileDelivery, WebSocketDelivery, WebhookDelivery,
}
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

@external(erlang, "springdrift_ffi", "generate_uuid")
fn generate_uuid() -> String

/// Deliver a report to the configured destination.
/// Returns Ok(destination_info) or Error(reason).
pub fn deliver(
  report: String,
  job_name: String,
  config: DeliveryConfig,
) -> Result(String, String) {
  case config {
    FileDelivery(directory:, format:) ->
      deliver_to_file(report, job_name, directory, format)
    WebhookDelivery(..) -> {
      slog.warn(
        "scheduler/delivery",
        "deliver",
        "Webhook delivery not yet implemented for job: " <> job_name,
        None,
      )
      Error("Webhook delivery not yet implemented")
    }
    WebSocketDelivery -> {
      slog.warn(
        "scheduler/delivery",
        "deliver",
        "WebSocket delivery not yet implemented for job: " <> job_name,
        None,
      )
      Error("WebSocket delivery not yet implemented")
    }
  }
}

fn deliver_to_file(
  report: String,
  job_name: String,
  directory: String,
  format: String,
) -> Result(String, String) {
  case simplifile.create_directory_all(directory) {
    Error(_) -> Error("Could not create directory: " <> directory)
    Ok(_) -> {
      let ext = case format {
        "json" -> ".json"
        "html" -> ".html"
        _ -> ".md"
      }
      let timestamp = sanitize_filename(get_datetime())
      let id = string.slice(generate_uuid(), 0, 8)
      let filename = job_name <> "_" <> timestamp <> "_" <> id <> ext
      let path = directory <> "/" <> filename
      case simplifile.write(path, report) {
        Ok(_) -> {
          slog.info(
            "scheduler/delivery",
            "deliver_to_file",
            "Delivered report to " <> path,
            None,
          )
          Ok(path)
        }
        Error(_) -> Error("Could not write report to: " <> path)
      }
    }
  }
}

fn sanitize_filename(s: String) -> String {
  string.replace(s, ":", "_")
  |> string.replace(" ", "_")
  |> string.replace("/", "_")
  |> string.replace("\\", "_")
}
