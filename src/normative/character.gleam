//// Character specification loading — reads character.json from identity
//// directories using the same discovery pattern as persona.md.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import normative/types.{
  type CharacterSpec, type Modality, type NormativeLevel, type NormativeOperator,
  type NormativeProposition, type Virtue, CharacterSpec, NormativeProposition,
  Virtue,
}
import simplifile
import slog

/// Filename for the character specification.
pub const character_filename = "character.json"

/// Load a character spec from identity directories (first match wins).
pub fn load_character(dirs: List(String)) -> Option(CharacterSpec) {
  let paths = list.map(dirs, fn(dir) { dir <> "/" <> character_filename })
  load_first(paths)
}

/// Decode a CharacterSpec from a JSON dynamic value.
pub fn decode_character(
  json_str: String,
) -> Result(CharacterSpec, json.DecodeError) {
  json.parse(json_str, character_decoder())
}

/// Default character spec with 5 basic virtues and 4 core normative commitments.
pub fn default_character() -> CharacterSpec {
  CharacterSpec(
    virtues: [
      Virtue(name: "honesty", expressions: [
        "accurate claims", "source attribution", "uncertainty acknowledgment",
      ]),
      Virtue(name: "care", expressions: [
        "user wellbeing", "proportionate caution",
      ]),
      Virtue(name: "wisdom", expressions: [
        "proportional response", "charitable interpretation",
      ]),
      Virtue(name: "integrity", expressions: [
        "consistent behaviour", "resistant to manipulation",
      ]),
      Virtue(name: "justice", expressions: [
        "fair treatment", "privacy respect", "respects autonomy",
      ]),
    ],
    highest_endeavour: [
      NormativeProposition(
        level: types.EthicalMoral,
        operator: types.Required,
        modality: types.Possible,
        description: "Be truthful in all claims",
      ),
      NormativeProposition(
        level: types.EthicalMoral,
        operator: types.Required,
        modality: types.Possible,
        description: "Avoid facilitating serious harm",
      ),
      NormativeProposition(
        level: types.IntellectualHonesty,
        operator: types.Ought,
        modality: types.Possible,
        description: "Cite sources for factual claims",
      ),
      NormativeProposition(
        level: types.UserAutonomy,
        operator: types.Ought,
        modality: types.Possible,
        description: "Respect user decisions and autonomy",
      ),
    ],
  )
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn load_first(paths: List(String)) -> Option(CharacterSpec) {
  case paths {
    [] -> None
    [path, ..rest] ->
      case simplifile.read(path) {
        Ok(contents) ->
          case decode_character(contents) {
            Ok(spec) -> {
              slog.info(
                "normative/character",
                "load",
                "Loaded character spec from " <> path,
                None,
              )
              Some(spec)
            }
            Error(_) -> {
              slog.warn(
                "normative/character",
                "load",
                "Failed to decode character spec from " <> path,
                None,
              )
              load_first(rest)
            }
          }
        Error(_) -> load_first(rest)
      }
  }
}

// ---------------------------------------------------------------------------
// JSON decoders
// ---------------------------------------------------------------------------

fn character_decoder() -> decode.Decoder(CharacterSpec) {
  use virtues <- decode.field("virtues", decode.list(virtue_decoder()))
  use highest_endeavour <- decode.field(
    "highest_endeavour",
    decode.list(normative_proposition_decoder()),
  )
  decode.success(CharacterSpec(virtues:, highest_endeavour:))
}

fn virtue_decoder() -> decode.Decoder(Virtue) {
  use name <- decode.field("name", decode.string)
  use expressions <- decode.field("expressions", decode.list(decode.string))
  decode.success(Virtue(name:, expressions:))
}

fn normative_proposition_decoder() -> decode.Decoder(NormativeProposition) {
  use level_str <- decode.field("level", decode.string)
  use op_str <- decode.field("operator", decode.string)
  use mod_str <- decode.field("modality", decode.string)
  use desc <- decode.field("description", decode.string)
  decode.success(NormativeProposition(
    level: parse_level(level_str),
    operator: parse_operator(op_str),
    modality: parse_modality(mod_str),
    description: desc,
  ))
}

/// Parse a normative level from a lowercase string.
pub fn parse_level(s: String) -> NormativeLevel {
  case s {
    "ethical_moral" -> types.EthicalMoral
    "legal" -> types.Legal
    "safety_physical" -> types.SafetyPhysical
    "privacy_data" -> types.PrivacyData
    "intellectual_honesty" -> types.IntellectualHonesty
    "professional_ethics" -> types.ProfessionalEthics
    "user_autonomy" -> types.UserAutonomy
    "transparency" -> types.Transparency
    "proportionality" -> types.Proportionality
    "efficiency" -> types.Efficiency
    "courtesy" -> types.Courtesy
    "stylistic" -> types.Stylistic
    "aesthetic" -> types.Aesthetic
    _ -> types.Operational
  }
}

/// Parse a normative operator from a lowercase string.
pub fn parse_operator(s: String) -> NormativeOperator {
  case s {
    "required" -> types.Required
    "ought" -> types.Ought
    _ -> types.Indifferent
  }
}

/// Parse a modality from a lowercase string.
pub fn parse_modality(s: String) -> Modality {
  case s {
    "impossible" -> types.Impossible
    _ -> types.Possible
  }
}

/// Encode a normative level to a lowercase string.
pub fn level_to_string(level: NormativeLevel) -> String {
  case level {
    types.EthicalMoral -> "ethical_moral"
    types.Legal -> "legal"
    types.SafetyPhysical -> "safety_physical"
    types.PrivacyData -> "privacy_data"
    types.IntellectualHonesty -> "intellectual_honesty"
    types.ProfessionalEthics -> "professional_ethics"
    types.UserAutonomy -> "user_autonomy"
    types.Transparency -> "transparency"
    types.Proportionality -> "proportionality"
    types.Efficiency -> "efficiency"
    types.Courtesy -> "courtesy"
    types.Stylistic -> "stylistic"
    types.Aesthetic -> "aesthetic"
    types.Operational -> "operational"
  }
}

/// Encode a normative operator to a lowercase string.
pub fn operator_to_string(op: NormativeOperator) -> String {
  case op {
    types.Required -> "required"
    types.Ought -> "ought"
    types.Indifferent -> "indifferent"
  }
}
