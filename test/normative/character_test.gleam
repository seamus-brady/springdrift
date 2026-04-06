// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleeunit
import gleeunit/should
import normative/character
import normative/types

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// decode_character — valid JSON
// ---------------------------------------------------------------------------

pub fn decode_valid_character_test() {
  let json =
    "{
    \"virtues\": [
      {\"name\": \"honesty\", \"expressions\": [\"accurate claims\", \"source attribution\"]}
    ],
    \"highest_endeavour\": [
      {\"level\": \"ethical_moral\", \"operator\": \"required\", \"modality\": \"possible\", \"description\": \"Be truthful\"}
    ]
  }"
  let result = character.decode_character(json)
  let assert Ok(spec) = result
  list.length(spec.virtues) |> should.equal(1)
  let assert [v] = spec.virtues
  v.name |> should.equal("honesty")
  list.length(v.expressions) |> should.equal(2)
  list.length(spec.highest_endeavour) |> should.equal(1)
  let assert [np] = spec.highest_endeavour
  np.level |> should.equal(types.EthicalMoral)
  np.operator |> should.equal(types.Required)
  np.modality |> should.equal(types.Possible)
  np.description |> should.equal("Be truthful")
}

// ---------------------------------------------------------------------------
// decode_character — malformed JSON
// ---------------------------------------------------------------------------

pub fn decode_malformed_json_test() {
  let result = character.decode_character("not json")
  should.be_error(result)
}

pub fn decode_missing_fields_test() {
  let json = "{\"virtues\": []}"
  let result = character.decode_character(json)
  should.be_error(result)
}

// ---------------------------------------------------------------------------
// parse_level
// ---------------------------------------------------------------------------

pub fn parse_level_all_known_test() {
  character.parse_level("ethical_moral") |> should.equal(types.EthicalMoral)
  character.parse_level("legal") |> should.equal(types.Legal)
  character.parse_level("safety_physical") |> should.equal(types.SafetyPhysical)
  character.parse_level("privacy_data") |> should.equal(types.PrivacyData)
  character.parse_level("intellectual_honesty")
  |> should.equal(types.IntellectualHonesty)
  character.parse_level("professional_ethics")
  |> should.equal(types.ProfessionalEthics)
  character.parse_level("user_autonomy") |> should.equal(types.UserAutonomy)
  character.parse_level("transparency") |> should.equal(types.Transparency)
  character.parse_level("proportionality")
  |> should.equal(types.Proportionality)
  character.parse_level("efficiency") |> should.equal(types.Efficiency)
  character.parse_level("courtesy") |> should.equal(types.Courtesy)
  character.parse_level("stylistic") |> should.equal(types.Stylistic)
  character.parse_level("aesthetic") |> should.equal(types.Aesthetic)
}

pub fn parse_level_unknown_defaults_operational_test() {
  character.parse_level("unknown") |> should.equal(types.Operational)
}

// ---------------------------------------------------------------------------
// parse_operator
// ---------------------------------------------------------------------------

pub fn parse_operator_all_known_test() {
  character.parse_operator("required") |> should.equal(types.Required)
  character.parse_operator("ought") |> should.equal(types.Ought)
}

pub fn parse_operator_unknown_defaults_indifferent_test() {
  character.parse_operator("unknown") |> should.equal(types.Indifferent)
}

// ---------------------------------------------------------------------------
// parse_modality
// ---------------------------------------------------------------------------

pub fn parse_modality_test() {
  character.parse_modality("possible") |> should.equal(types.Possible)
  character.parse_modality("impossible") |> should.equal(types.Impossible)
  character.parse_modality("unknown") |> should.equal(types.Possible)
}

// ---------------------------------------------------------------------------
// default_character
// ---------------------------------------------------------------------------

pub fn default_character_has_virtues_test() {
  let spec = character.default_character()
  list.length(spec.virtues) |> should.equal(5)
}

pub fn default_character_has_endeavour_test() {
  let spec = character.default_character()
  list.length(spec.highest_endeavour) |> should.equal(4)
}

// ---------------------------------------------------------------------------
// load_character — missing directory
// ---------------------------------------------------------------------------

pub fn load_character_missing_dir_test() {
  character.load_character(["/tmp/nonexistent_dir_12345"])
  |> should.be_none()
}

// ---------------------------------------------------------------------------
// Round-trip level/operator strings
// ---------------------------------------------------------------------------

pub fn level_roundtrip_test() {
  character.parse_level(character.level_to_string(types.EthicalMoral))
  |> should.equal(types.EthicalMoral)
  character.parse_level(character.level_to_string(types.Operational))
  |> should.equal(types.Operational)
}

pub fn operator_roundtrip_test() {
  character.parse_operator(character.operator_to_string(types.Required))
  |> should.equal(types.Required)
  character.parse_operator(character.operator_to_string(types.Indifferent))
  |> should.equal(types.Indifferent)
}

import gleam/list
