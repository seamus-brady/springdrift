//// Agent workspace — journal, notes, drafts.

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option
import gleam/string
import simplifile
import slog

@external(erlang, "springdrift_ffi", "get_date")
fn get_date() -> String

/// Append a journal entry to today's journal file.
pub fn write_journal(
  journal_dir: String,
  content: String,
) -> Result(Nil, String) {
  let _ = simplifile.create_directory_all(journal_dir)
  let date = get_date()
  let path = journal_dir <> "/" <> date <> ".md"
  let entry = "\n---\n\n" <> string.trim(content) <> "\n"
  case simplifile.append(path, entry) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> {
      let msg = "Failed to write journal: " <> string.inspect(reason)
      slog.log_error("workspace", "write_journal", msg, option.None)
      Error(msg)
    }
  }
}

/// Read today's journal entries.
pub fn read_journal_today(journal_dir: String) -> String {
  let date = get_date()
  read_journal(journal_dir, date)
}

/// Read journal entries for a specific date.
pub fn read_journal(journal_dir: String, date: String) -> String {
  let path = journal_dir <> "/" <> date <> ".md"
  case simplifile.read(path) {
    Ok(content) -> content
    Error(_) -> ""
  }
}

/// Create or update a working note.
pub fn write_note(
  notes_dir: String,
  slug: String,
  content: String,
) -> Result(Nil, String) {
  let _ = simplifile.create_directory_all(notes_dir)
  let safe_slug = sanitize_slug(slug)
  let path = notes_dir <> "/" <> safe_slug <> ".md"
  case simplifile.write(path, content) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> {
      let msg = "Failed to write note: " <> string.inspect(reason)
      slog.log_error("workspace", "write_note", msg, option.None)
      Error(msg)
    }
  }
}

/// Read a working note by slug.
pub fn read_note(notes_dir: String, slug: String) -> Result(String, String) {
  let safe_slug = sanitize_slug(slug)
  let path = notes_dir <> "/" <> safe_slug <> ".md"
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(_) -> Error("Note not found: " <> slug)
  }
}

/// List all notes (returns slug list).
pub fn list_notes(notes_dir: String) -> List(String) {
  case simplifile.read_directory(notes_dir) {
    Ok(files) ->
      files
      |> list_md_files
    Error(_) -> []
  }
}

/// Create or update a draft report.
pub fn write_draft(
  drafts_dir: String,
  slug: String,
  content: String,
) -> Result(Nil, String) {
  let _ = simplifile.create_directory_all(drafts_dir)
  let safe_slug = sanitize_slug(slug)
  let path = drafts_dir <> "/" <> safe_slug <> ".md"
  case simplifile.write(path, content) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> {
      let msg = "Failed to write draft: " <> string.inspect(reason)
      slog.log_error("workspace", "write_draft", msg, option.None)
      Error(msg)
    }
  }
}

/// Read a draft report by slug.
pub fn read_draft(drafts_dir: String, slug: String) -> Result(String, String) {
  let safe_slug = sanitize_slug(slug)
  let path = drafts_dir <> "/" <> safe_slug <> ".md"
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(_) -> Error("Draft not found: " <> slug)
  }
}

/// List all drafts (returns slug list).
pub fn list_drafts(drafts_dir: String) -> List(String) {
  case simplifile.read_directory(drafts_dir) {
    Ok(files) -> list_md_files(files)
    Error(_) -> []
  }
}

fn list_md_files(files: List(String)) -> List(String) {
  files
  |> list.filter(fn(f) { string.ends_with(f, ".md") })
  |> list.map(fn(f) { string.drop_end(f, 3) })
}

import gleam/list

fn sanitize_slug(slug: String) -> String {
  slug
  |> string.lowercase
  |> string.replace(" ", "-")
  |> string.replace("/", "-")
  |> string.replace("..", "")
  |> string.trim
}
