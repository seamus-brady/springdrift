// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import llm/tool as tool_builder

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn build_minimal_tool_test() {
  let t = tool_builder.new("my_tool") |> tool_builder.build
  t.name |> should.equal("my_tool")
  t.parameters |> should.equal([])
  t.required_params |> should.equal([])
}

pub fn with_description_test() {
  let t =
    tool_builder.new("my_tool")
    |> tool_builder.with_description("A useful tool")
    |> tool_builder.build
  t.description |> should.equal(Some("A useful tool"))
}

pub fn add_string_param_required_test() {
  let t =
    tool_builder.new("my_tool")
    |> tool_builder.add_string_param("name", "The name", True)
    |> tool_builder.build
  list.length(t.parameters) |> should.equal(1)
  t.required_params |> should.equal(["name"])
}

pub fn add_optional_param_not_in_required_test() {
  let t =
    tool_builder.new("my_tool")
    |> tool_builder.add_string_param("optional_field", "Optional", False)
    |> tool_builder.build
  list.length(t.parameters) |> should.equal(1)
  t.required_params |> should.equal([])
}

pub fn add_enum_param_values_test() {
  let t =
    tool_builder.new("my_tool")
    |> tool_builder.add_enum_param(
      "color",
      "A color",
      ["red", "green", "blue"],
      True,
    )
    |> tool_builder.build
  let assert [#("color", schema)] = t.parameters
  schema.enum_values |> should.equal(Some(["red", "green", "blue"]))
}

pub fn multi_param_test() {
  let t =
    tool_builder.new("my_tool")
    |> tool_builder.add_string_param("name", "Name", True)
    |> tool_builder.add_integer_param("count", "Count", True)
    |> tool_builder.add_boolean_param("verbose", "Verbose mode", False)
    |> tool_builder.build
  list.length(t.parameters) |> should.equal(3)
  t.required_params |> should.equal(["name", "count"])
}
