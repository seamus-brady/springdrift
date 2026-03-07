//// Scheduler delivery — write finished reports to configured destinations.

import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import profile/types.{type DeliveryConfig, FileDelivery, WebhookDelivery}
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
    WebhookDelivery(url:, method:, headers:) ->
      deliver_to_webhook(report, job_name, url, method, headers)
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

fn deliver_to_webhook(
  content: String,
  job_name: String,
  url: String,
  method: String,
  headers: List(#(String, String)),
) -> Result(String, String) {
  let method_lower = string.lowercase(method)
  let http_method =
    http.parse_method(method_lower)
    |> result.unwrap(http.Post)

  case request.to(url) {
    Error(_) -> {
      slog.warn(
        "scheduler/delivery",
        "deliver_to_webhook",
        "Invalid webhook URL for job '" <> job_name <> "': " <> url,
        None,
      )
      Error("Invalid webhook URL: " <> url)
    }
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http_method)
        |> request.set_body(content)
        |> request.set_header("content-type", "application/json")
      let req =
        list.fold(headers, req, fn(r, h) { request.set_header(r, h.0, h.1) })
      case httpc.send(req) {
        Ok(resp) -> {
          case resp.status >= 200 && resp.status < 300 {
            True -> {
              slog.info(
                "scheduler/delivery",
                "deliver_to_webhook",
                "Delivered report for job '" <> job_name <> "' to " <> url,
                None,
              )
              Ok(url)
            }
            False -> {
              let reason =
                "Webhook returned status "
                <> int.to_string(resp.status)
                <> " for job '"
                <> job_name
                <> "'"
              slog.warn(
                "scheduler/delivery",
                "deliver_to_webhook",
                reason,
                None,
              )
              Error(reason)
            }
          }
        }
        Error(_) -> {
          let reason =
            "Connection failed for webhook job '" <> job_name <> "': " <> url
          slog.warn("scheduler/delivery", "deliver_to_webhook", reason, None)
          Error(reason)
        }
      }
    }
  }
}
