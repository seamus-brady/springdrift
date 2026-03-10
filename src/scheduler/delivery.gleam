//// Scheduler delivery — write finished reports to configured destinations.

import gleam/http
import gleam/http/request
import gleam/http/response as http_response
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

/// Type for injectable HTTP sender — matches `httpc.send` signature.
pub type HttpSender =
  fn(request.Request(String)) ->
    Result(http_response.Response(String), httpc.HttpError)

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
      deliver_to_webhook(report, job_name, url, method, headers, httpc.send)
  }
}

/// Deliver with an injectable HTTP sender — for testing without real HTTP.
pub fn deliver_with_sender(
  report: String,
  job_name: String,
  config: DeliveryConfig,
  sender: HttpSender,
) -> Result(String, String) {
  case config {
    FileDelivery(directory:, format:) ->
      deliver_to_file(report, job_name, directory, format)
    WebhookDelivery(url:, method:, headers:) ->
      deliver_to_webhook(report, job_name, url, method, headers, sender)
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
  |> string.replace("?", "_")
  |> string.replace("*", "_")
  |> string.replace("<", "_")
  |> string.replace(">", "_")
  |> string.replace("\"", "_")
  |> string.replace("|", "_")
}

fn deliver_to_webhook(
  content: String,
  job_name: String,
  url: String,
  method: String,
  headers: List(#(String, String)),
  sender: HttpSender,
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
      // Apply user headers first, then set content-type default only if
      // the user didn't provide one. This lets webhook configs override
      // the default for non-JSON payloads (markdown, HTML reports).
      let req =
        req
        |> request.set_method(http_method)
        |> request.set_body(content)
      let req =
        list.fold(headers, req, fn(r, h) { request.set_header(r, h.0, h.1) })
      let has_content_type =
        list.any(headers, fn(h) { string.lowercase(h.0) == "content-type" })
      let req = case has_content_type {
        True -> req
        False -> request.set_header(req, "content-type", "application/json")
      }
      case sender(req) {
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
