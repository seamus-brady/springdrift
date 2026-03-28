//// Backup actor — OTP process managing automated git backup of .springdrift/.
////
//// Trigger modes:
////   - after_cycle: commit after every N cognitive cycles
////   - periodic: commit on a timer
////   - manual: operator triggers via BackupNow message
////
//// The actor owns the git repo lifecycle: init on start, commit on
//// trigger, push on schedule. Failures are logged and surfaced as
//// sensory events.

import backup/git
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import slog

@external(erlang, "springdrift_ffi", "get_datetime")
fn get_datetime() -> String

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type BackupMessage {
  /// Trigger a backup (commit + optional push)
  BackupNow
  /// Called after a cognitive cycle completes
  CycleComplete(cycle_id: String, summary: String)
  /// Get current status
  GetStatus(reply_to: Subject(BackupStatus))
  /// Periodic tick (self-scheduled via send_after)
  Tick
  /// Shutdown
  Shutdown
}

pub type BackupStatus {
  BackupStatus(
    enabled: Bool,
    last_backup: Option(String),
    last_commit: Option(String),
    commits_total: Int,
    last_error: Option(String),
  )
}

pub type BackupConfig {
  BackupConfig(
    enabled: Bool,
    data_dir: String,
    /// "after_cycle" | "periodic" | "manual"
    mode: String,
    /// Commit every N cycles (after_cycle mode)
    cycle_interval: Int,
    /// Periodic commit interval in ms
    periodic_interval_ms: Int,
    /// Remote URL (None = local only)
    remote_url: Option(String),
    /// Branch name
    branch: String,
    /// Push interval in ms (0 = after every commit)
    push_interval_ms: Int,
  )
}

pub type BackupState {
  BackupState(
    config: BackupConfig,
    self: Subject(BackupMessage),
    cycles_since_commit: Int,
    last_backup: Option(String),
    last_commit: Option(String),
    commits_total: Int,
    last_error: Option(String),
    pending_cycle_summaries: List(String),
  )
}

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub fn default_config(data_dir: String) -> BackupConfig {
  BackupConfig(
    enabled: False,
    data_dir:,
    mode: "after_cycle",
    cycle_interval: 1,
    periodic_interval_ms: 3_600_000,
    remote_url: None,
    branch: "main",
    push_interval_ms: 3_600_000,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the backup actor. Returns a Subject for sending messages.
pub fn start(config: BackupConfig) -> Result(Subject(BackupMessage), String) {
  case config.enabled {
    False -> {
      slog.info("backup/actor", "start", "Backup disabled", None)
      Error("Backup disabled")
    }
    True -> {
      // Initialise git repo
      case git.init(config.data_dir) {
        Error(e) -> {
          slog.log_error(
            "backup/actor",
            "start",
            "Failed to init git repo: " <> e,
            None,
          )
          Error(e)
        }
        Ok(_) -> {
          // Configure remote if specified and not already present
          case config.remote_url {
            Some(url) ->
              case git.has_remote(config.data_dir, "origin") {
                True -> Nil
                False -> {
                  case git.add_remote(config.data_dir, "origin", url) {
                    Ok(_) ->
                      slog.info(
                        "backup/actor",
                        "start",
                        "Added git remote: " <> url,
                        None,
                      )
                    Error(e) ->
                      slog.warn(
                        "backup/actor",
                        "start",
                        "Failed to add remote: " <> e,
                        None,
                      )
                  }
                }
              }
            None -> Nil
          }
          let self = process.new_subject()
          process.spawn_unlinked(fn() {
            let state =
              BackupState(
                config:,
                self:,
                cycles_since_commit: 0,
                last_backup: None,
                last_commit: git.last_commit_hash(config.data_dir),
                commits_total: git.commit_count(config.data_dir),
                last_error: None,
                pending_cycle_summaries: [],
              )

            // Schedule periodic tick if in periodic mode
            case config.mode {
              "periodic" -> schedule_tick(self, config.periodic_interval_ms)
              _ -> Nil
            }

            // Initial commit for any uncommitted state
            let state = do_backup(state, "Initial backup on startup")

            slog.info(
              "backup/actor",
              "start",
              "Backup actor started (mode: "
                <> config.mode
                <> ", commits: "
                <> int.to_string(state.commits_total)
                <> ")",
              None,
            )

            loop(state)
          })

          Ok(self)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Actor loop
// ---------------------------------------------------------------------------

fn loop(state: BackupState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(state.self)
  let msg = process.selector_receive_forever(selector)
  case msg {
    BackupNow -> {
      let state = do_backup(state, "Manual backup")
      loop(state)
    }

    CycleComplete(cycle_id:, summary:) -> {
      let summaries = [summary, ..state.pending_cycle_summaries]
      let cycles = state.cycles_since_commit + 1

      case cycles >= state.config.cycle_interval {
        True -> {
          // Time to commit
          let message = build_commit_message(summaries, cycle_id)
          let state =
            do_backup(
              BackupState(
                ..state,
                pending_cycle_summaries: [],
                cycles_since_commit: 0,
              ),
              message,
            )
          loop(state)
        }
        False -> {
          loop(
            BackupState(
              ..state,
              pending_cycle_summaries: summaries,
              cycles_since_commit: cycles,
            ),
          )
        }
      }
    }

    GetStatus(reply_to:) -> {
      process.send(
        reply_to,
        BackupStatus(
          enabled: state.config.enabled,
          last_backup: state.last_backup,
          last_commit: state.last_commit,
          commits_total: state.commits_total,
          last_error: state.last_error,
        ),
      )
      loop(state)
    }

    Tick -> {
      let state = do_backup(state, "Periodic backup")
      schedule_tick(state.self, state.config.periodic_interval_ms)
      loop(state)
    }

    Shutdown -> {
      // Final backup before shutdown
      let _ = do_backup(state, "Shutdown backup")
      slog.info("backup/actor", "loop", "Backup actor stopped", None)
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn do_backup(state: BackupState, message: String) -> BackupState {
  let now = get_datetime()
  case git.commit(state.config.data_dir, message) {
    Ok(Some(hash)) -> {
      slog.info("backup/actor", "do_backup", "Committed: " <> hash, None)
      // Try push if remote configured — warn if not
      let push_error = case state.config.remote_url {
        None -> {
          slog.warn(
            "backup/actor",
            "do_backup",
            "No remote configured — backup is local only. Set [backup] remote_url for offsite safety.",
            None,
          )
          None
        }
        Some(_) ->
          case git.push(state.config.data_dir, "origin", state.config.branch) {
            Ok(_) -> None
            Error(e) -> {
              slog.warn("backup/actor", "do_backup", "Push failed: " <> e, None)
              Some(e)
            }
          }
      }
      BackupState(
        ..state,
        last_backup: Some(now),
        last_commit: Some(hash),
        commits_total: state.commits_total + 1,
        last_error: push_error,
      )
    }
    Ok(None) -> {
      // Nothing to commit
      state
    }
    Error(e) -> {
      slog.warn("backup/actor", "do_backup", "Backup failed: " <> e, None)
      BackupState(..state, last_error: Some(e))
    }
  }
}

fn build_commit_message(
  summaries: List(String),
  last_cycle_id: String,
) -> String {
  let cycle_short = string.slice(last_cycle_id, 0, 8)
  let n = int.to_string(list.length(summaries))
  case summaries {
    [] -> "Backup: no cycles"
    [single] -> "Cycle " <> cycle_short <> ": " <> single
    _ ->
      n
      <> " cycles (latest: "
      <> cycle_short
      <> ")\n\n"
      <> string.join(list.reverse(summaries), "\n")
  }
}

fn schedule_tick(self: Subject(BackupMessage), delay_ms: Int) -> Nil {
  let _ = process.send_after(self, delay_ms, Tick)
  Nil
}

import gleam/list
