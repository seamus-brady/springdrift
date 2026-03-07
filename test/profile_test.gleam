import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import profile
import profile/types.{FileDelivery, WebhookDelivery}
import simplifile

// ---------------------------------------------------------------------------
// parse_interval
// ---------------------------------------------------------------------------

pub fn parse_interval_hours_test() {
  profile.parse_interval("24h") |> should.equal(86_400_000)
}

pub fn parse_interval_minutes_test() {
  profile.parse_interval("30m") |> should.equal(1_800_000)
}

pub fn parse_interval_seconds_test() {
  profile.parse_interval("60s") |> should.equal(60_000)
}

pub fn parse_interval_days_test() {
  profile.parse_interval("1d") |> should.equal(86_400_000)
}

pub fn parse_interval_six_hours_test() {
  profile.parse_interval("6h") |> should.equal(21_600_000)
}

pub fn parse_interval_invalid_returns_default_test() {
  profile.parse_interval("xyz") |> should.equal(86_400_000)
}

pub fn parse_interval_empty_returns_default_test() {
  profile.parse_interval("") |> should.equal(86_400_000)
}

pub fn parse_interval_single_char_returns_default_test() {
  profile.parse_interval("h") |> should.equal(86_400_000)
}

pub fn parse_interval_with_whitespace_test() {
  profile.parse_interval("  12h  ") |> should.equal(43_200_000)
}

// ---------------------------------------------------------------------------
// discover — with temp directories
// ---------------------------------------------------------------------------

pub fn discover_empty_dir_test() {
  let dir = "/tmp/springdrift_test_discover_empty"
  let _ = simplifile.create_directory_all(dir)
  let result = profile.discover([dir])
  // No profiles in empty dir
  result |> should.equal([])
  let _ = simplifile.delete(dir)
  Nil
}

pub fn discover_finds_profiles_test() {
  let dir = "/tmp/springdrift_test_discover_profiles"
  let profile_dir = dir <> "/myprofile"
  let _ = simplifile.create_directory_all(profile_dir)
  let _ =
    simplifile.write(
      profile_dir <> "/config.toml",
      "[profile]\nname = \"myprofile\"\n",
    )
  let result = profile.discover([dir])
  result |> should.equal(["myprofile"])
  let _ = simplifile.delete(dir)
  Nil
}

pub fn discover_ignores_dirs_without_config_test() {
  let dir = "/tmp/springdrift_test_discover_no_config"
  let profile_dir = dir <> "/noconfig"
  let _ = simplifile.create_directory_all(profile_dir)
  let _ = simplifile.write(profile_dir <> "/readme.txt", "not a profile")
  let result = profile.discover([dir])
  result |> should.equal([])
  let _ = simplifile.delete(dir)
  Nil
}

pub fn discover_nonexistent_dir_test() {
  let result = profile.discover(["/tmp/springdrift_nonexistent_dir_xyz"])
  result |> should.equal([])
}

// ---------------------------------------------------------------------------
// load — profile parsing
// ---------------------------------------------------------------------------

pub fn load_minimal_profile_test() {
  let dir = "/tmp/springdrift_test_load_minimal"
  let profile_dir = dir <> "/minimal"
  let _ = simplifile.create_directory_all(profile_dir)
  let _ =
    simplifile.write(
      profile_dir <> "/config.toml",
      "[profile]\ndescription = \"A minimal profile\"\n",
    )
  let result = profile.load("minimal", [dir])
  result |> should.be_ok
  let assert Ok(p) = result
  p.name |> should.equal("minimal")
  p.description |> should.equal("A minimal profile")
  p.agents |> should.equal([])
  p.dprime_path |> should.equal(None)
  p.schedule_path |> should.equal(None)
  p.skills_dir |> should.equal(None)
  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_profile_with_models_test() {
  let dir = "/tmp/springdrift_test_load_models"
  let profile_dir = dir <> "/modeled"
  let _ = simplifile.create_directory_all(profile_dir)
  let _ =
    simplifile.write(
      profile_dir <> "/config.toml",
      "[models]\ntask_model = \"gpt-4o-mini\"\nreasoning_model = \"gpt-4o\"\n",
    )
  let result = profile.load("modeled", [dir])
  result |> should.be_ok
  let assert Ok(p) = result
  p.models.task_model |> should.equal(Some("gpt-4o-mini"))
  p.models.reasoning_model |> should.equal(Some("gpt-4o"))
  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_profile_with_agents_test() {
  let dir = "/tmp/springdrift_test_load_agents"
  let profile_dir = dir <> "/agented"
  let _ = simplifile.create_directory_all(profile_dir)
  let toml =
    "[[agents]]\nname = \"researcher\"\ndescription = \"Research agent\"\ntools = [\"web\", \"files\"]\nmax_turns = 8\n\n[[agents]]\nname = \"writer\"\ndescription = \"Writer agent\"\ntools = [\"files\", \"builtin\"]\nmax_turns = 5\n"
  let _ = simplifile.write(profile_dir <> "/config.toml", toml)
  let result = profile.load("agented", [dir])
  result |> should.be_ok
  let assert Ok(p) = result
  list.length(p.agents) |> should.equal(2)
  let assert Ok(first) = list.first(p.agents)
  first.name |> should.equal("researcher")
  first.description |> should.equal("Research agent")
  first.tools |> should.equal(["web", "files"])
  first.max_turns |> should.equal(8)
  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_profile_with_dprime_test() {
  let dir = "/tmp/springdrift_test_load_dprime"
  let profile_dir = dir <> "/dptest"
  let _ = simplifile.create_directory_all(profile_dir)
  let _ =
    simplifile.write(
      profile_dir <> "/config.toml",
      "[profile]\nname = \"dp\"\n",
    )
  let _ = simplifile.write(profile_dir <> "/dprime.json", "{}")
  let result = profile.load("dptest", [dir])
  result |> should.be_ok
  let assert Ok(p) = result
  p.dprime_path |> should.equal(Some(profile_dir <> "/dprime.json"))
  let _ = simplifile.delete(dir)
  Nil
}

pub fn load_profile_not_found_test() {
  let result = profile.load("nonexistent", ["/tmp/springdrift_test_notfound"])
  result |> should.be_error
}

pub fn load_profile_default_description_test() {
  let dir = "/tmp/springdrift_test_load_default_desc"
  let profile_dir = dir <> "/nodesc"
  let _ = simplifile.create_directory_all(profile_dir)
  let _ = simplifile.write(profile_dir <> "/config.toml", "# empty config\n")
  let result = profile.load("nodesc", [dir])
  result |> should.be_ok
  let assert Ok(p) = result
  p.description |> should.equal("nodesc profile")
  let _ = simplifile.delete(dir)
  Nil
}

// ---------------------------------------------------------------------------
// parse_schedule
// ---------------------------------------------------------------------------

pub fn parse_schedule_basic_test() {
  let path = "/tmp/springdrift_test_schedule.toml"
  let _ =
    simplifile.write(
      path,
      "[[tasks]]\nname = \"daily-report\"\nquery = \"Summarize today\"\ninterval = \"24h\"\n",
    )
  let result = profile.parse_schedule(path)
  result |> should.be_ok
  let assert Ok(tasks) = result
  list.length(tasks) |> should.equal(1)
  let assert Ok(task) = list.first(tasks)
  task.name |> should.equal("daily-report")
  task.query |> should.equal("Summarize today")
  task.interval_ms |> should.equal(86_400_000)
  let _ = simplifile.delete(path)
  Nil
}

pub fn parse_schedule_missing_file_test() {
  let result = profile.parse_schedule("/tmp/springdrift_no_such_schedule.toml")
  result |> should.be_error
}

pub fn parse_schedule_file_delivery_test() {
  let path = "/tmp/springdrift_test_schedule_delivery.toml"
  let _ =
    simplifile.write(
      path,
      "[[tasks]]\nname = \"report\"\nquery = \"Generate report\"\ninterval = \"6h\"\ndelivery = \"file\"\n\n[delivery.file]\ndirectory = \"./output\"\nformat = \"markdown\"\n",
    )
  let result = profile.parse_schedule(path)
  result |> should.be_ok
  let assert Ok(tasks) = result
  let assert Ok(task) = list.first(tasks)
  case task.delivery {
    FileDelivery(directory:, format:) -> {
      directory |> should.equal("./output")
      format |> should.equal("markdown")
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(path)
  Nil
}

pub fn parse_schedule_webhook_delivery_test() {
  let path = "/tmp/springdrift_test_schedule_webhook.toml"
  let _ =
    simplifile.write(
      path,
      "[[tasks]]\nname = \"alert\"\nquery = \"Check status\"\ninterval = \"1h\"\ndelivery = \"webhook\"\n\n[delivery.webhook]\nurl = \"https://example.com/hook\"\nmethod = \"POST\"\n",
    )
  let result = profile.parse_schedule(path)
  result |> should.be_ok
  let assert Ok(tasks) = result
  let assert Ok(task) = list.first(tasks)
  case task.delivery {
    WebhookDelivery(url:, method:, ..) -> {
      url |> should.equal("https://example.com/hook")
      method |> should.equal("POST")
    }
    _ -> should.fail()
  }
  let _ = simplifile.delete(path)
  Nil
}
