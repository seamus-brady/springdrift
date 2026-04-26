//// Sandbox admin tool — `sandbox_reset`. Last-resort escape hatch
//// for the agent when both auto-recoveries (sandbox manager + coder
//// manager) have failed and the agent observes that container state
//// is wedged.
////
//// The tool deliberately bypasses the manager actors and talks
//// directly to podman, so it works even when a manager is itself
//// stuck on a corrupted slot. The next sandbox or coder dispatch
//// rebuilds containers from scratch.
////
//// Auto-recovery in `sandbox/manager.gleam` and `coder/manager.gleam`
//// is the load-bearing fix; this tool exists for the cases the
//// auto path misses (containers in odd intermediate states, image
//// trouble that didn't trigger the heuristic, operator wants a
//// clean slate without restarting the process).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import llm/tool
import llm/types.{
  type Tool, type ToolCall, type ToolResult, ToolFailure, ToolSuccess,
}
import sandbox/podman_ffi
import sandbox/recovery

/// Image references the reset action knows about. The cog loop wires
/// this in from config; tools that don't have a coder image set the
/// coder field to None so the tool only touches the sandbox image.
pub type ResetImages {
  ResetImages(sandbox_image: String, coder_image: String)
}

pub fn reset_tool() -> Tool {
  tool.new("sandbox_reset")
  |> tool.with_description(
    "Last-resort recovery for wedged container state. Force-removes "
    <> "every springdrift-sandbox-* and (optionally) springdrift-coder-* "
    <> "container, optionally re-pulls the configured images, and "
    <> "returns counts. Use this when sandbox tools repeatedly fail "
    <> "with image / container errors AND the auto-recovery hasn't "
    <> "fixed it. The next sandbox or coder dispatch rebuilds "
    <> "containers from scratch. Safe to call when nothing is wrong "
    <> "(it'll just remove zero containers).",
  )
  |> tool.add_boolean_param(
    "purge_coder",
    "Also remove springdrift-coder-* containers (default: true).",
    False,
  )
  |> tool.add_boolean_param(
    "repull_image",
    "After purge, force-remove and re-pull the sandbox + coder images. "
      <> "Use when the failure looks image-related (manifest unknown, "
      <> "layer corrupt, image not known). Slow — pull may take "
      <> "minutes (default: false).",
    False,
  )
  |> tool.build()
}

pub fn is_sandbox_admin_tool(name: String) -> Bool {
  name == "sandbox_reset"
}

/// Execute the reset. Pure-ish — the only side effects are podman
/// commands; it returns a human-readable summary either way.
pub fn execute(call: ToolCall, images: ResetImages) -> ToolResult {
  case call.name {
    "sandbox_reset" -> execute_reset(call, images)
    _ ->
      ToolFailure(
        tool_use_id: call.id,
        error: "Unknown sandbox_admin tool: " <> call.name,
      )
  }
}

fn execute_reset(call: ToolCall, images: ResetImages) -> ToolResult {
  let decoder = {
    use purge_coder <- decode.optional_field("purge_coder", True, decode.bool)
    use repull_image <- decode.optional_field(
      "repull_image",
      False,
      decode.bool,
    )
    decode.success(#(purge_coder, repull_image))
  }
  let #(purge_coder, repull_image) = case json.parse(call.input_json, decoder) {
    Ok(t) -> t
    Error(_) -> #(True, False)
  }

  let sandbox_removed = purge_by_prefix("springdrift-sandbox")
  let coder_removed = case purge_coder {
    True -> purge_by_prefix("springdrift-coder")
    False -> 0
  }

  let pull_lines = case repull_image {
    False -> []
    True -> {
      let sandbox_pull = pull_summary(images.sandbox_image)
      let coder_pull = case purge_coder {
        True -> pull_summary(images.coder_image)
        False -> "skipped (purge_coder=false)"
      }
      [
        "sandbox image (" <> images.sandbox_image <> "): " <> sandbox_pull,
        "coder image (" <> images.coder_image <> "): " <> coder_pull,
      ]
    }
  }

  let summary = [
    "Removed "
      <> int.to_string(sandbox_removed)
      <> " springdrift-sandbox-* container(s)",
    "Removed "
      <> int.to_string(coder_removed)
      <> " springdrift-coder-* container(s)"
      <> case purge_coder {
      True -> ""
      False -> " (skipped — purge_coder=false)"
    },
  ]
  let summary = case pull_lines {
    [] -> summary
    _ -> list.append(summary, ["Image re-pull:", ..pull_lines])
  }
  let summary =
    list.append(summary, [
      "Next sandbox/coder dispatch will rebuild containers automatically.",
    ])

  ToolSuccess(tool_use_id: call.id, content: string.join(summary, "\n"))
}

/// `podman ps -a --filter name=<prefix>-` then `podman rm -f` each.
/// Returns the count actually removed (zero on podman error).
pub fn purge_by_prefix(prefix: String) -> Int {
  case
    podman_ffi.run_cmd(
      "podman",
      [
        "ps",
        "-a",
        "--filter",
        "name=" <> prefix <> "-",
        "--format",
        "{{.Names}}",
      ],
      10_000,
    )
  {
    Ok(result) ->
      case result.exit_code {
        0 -> {
          let names =
            result.stdout
            |> string.trim
            |> string.split("\n")
            |> list.filter(fn(n) { n != "" })
          list.each(names, fn(name) {
            let _ = podman_ffi.run_cmd("podman", ["rm", "-f", name], 10_000)
            Nil
          })
          list.length(names)
        }
        _ -> 0
      }
    Error(_) -> 0
  }
}

fn pull_summary(image: String) -> String {
  case recovery.recover_image(image, 300_000) {
    Ok(_) -> "re-pulled"
    Error(msg) -> "failed (" <> msg <> ")"
  }
}
