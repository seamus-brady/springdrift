// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleeunit/should
import remembrancer/consolidation
import simplifile

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/remembrancer_consolidation_test_" <> suffix
  let _ = simplifile.create_directory_all(dir)
  case simplifile.read_directory(dir) {
    Ok(files) ->
      list.each(files, fn(f) {
        let _ = simplifile.delete(dir <> "/" <> f)
        Nil
      })
    Error(_) -> Nil
  }
  dir
}

pub fn append_then_load_all_test() {
  let dir = test_dir("append_load")
  let base = consolidation.new_run("2026-03-01", "2026-03-07", "first run")
  let run =
    consolidation.ConsolidationRun(
      ..base,
      patterns_found: 2,
      facts_restored: 1,
      threads_resurrected: 1,
      report_path: "/tmp/r.md",
    )
  consolidation.append(dir, run)
  let runs = consolidation.load_all(dir)
  list.length(runs) |> should.equal(1)
  case runs {
    [r, ..] -> {
      r.patterns_found |> should.equal(2)
      r.facts_restored |> should.equal(1)
      r.summary |> should.equal("first run")
    }
    [] -> should.fail()
  }
}

pub fn last_run_returns_latest_test() {
  let dir = test_dir("last_run")
  consolidation.append(
    dir,
    consolidation.new_run("2026-03-01", "2026-03-07", "run A"),
  )
  consolidation.append(
    dir,
    consolidation.new_run("2026-03-08", "2026-03-14", "run B"),
  )
  case consolidation.last_run(dir) {
    Ok(r) -> r.summary |> should.equal("run B")
    Error(_) -> should.fail()
  }
}

pub fn last_run_on_empty_dir_errors_test() {
  let dir = test_dir("empty")
  case consolidation.last_run(dir) {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
}

pub fn write_report_creates_file_test() {
  let dir = test_dir("report")
  case
    consolidation.write_report(
      dir,
      "Weekly Review",
      "# Report\n\nContent here.",
    )
  {
    Ok(path) -> {
      let content = simplifile.read(path)
      case content {
        Ok(body) ->
          body
          |> should.equal("# Report\n\nContent here.")
        Error(_) -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}
