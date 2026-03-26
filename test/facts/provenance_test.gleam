import facts/log as facts_log
import facts/types.{
  type MemoryFact, DirectObservation, FactProvenance, MemoryFact,
  OperatorProvided, Session, Synthesis, Unknown, Write,
}
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_fact_with_provenance(
  fact_id: String,
  key: String,
  value: String,
  provenance: option.Option(types.FactProvenance),
) -> MemoryFact {
  MemoryFact(
    schema_version: 1,
    fact_id:,
    timestamp: "2026-03-25T10:00:00",
    cycle_id: "cycle-prov-001",
    agent_id: Some("cognitive"),
    key:,
    value:,
    scope: Session,
    operation: Write,
    supersedes: None,
    confidence: 0.85,
    source: "memory_write_tool",
    provenance:,
  )
}

fn sample_provenance() -> types.FactProvenance {
  FactProvenance(
    source_cycle_id: "cycle-abc123",
    source_tool: "memory_write",
    source_agent: "cognitive",
    derivation: Synthesis,
  )
}

// ---------------------------------------------------------------------------
// Construction tests
// ---------------------------------------------------------------------------

pub fn provenance_construction_test() {
  let prov = sample_provenance()
  prov.source_cycle_id |> should.equal("cycle-abc123")
  prov.source_tool |> should.equal("memory_write")
  prov.source_agent |> should.equal("cognitive")
  prov.derivation |> should.equal(Synthesis)
}

pub fn provenance_all_derivations_test() {
  let direct =
    FactProvenance(..sample_provenance(), derivation: DirectObservation)
  direct.derivation |> should.equal(DirectObservation)

  let synth = FactProvenance(..sample_provenance(), derivation: Synthesis)
  synth.derivation |> should.equal(Synthesis)

  let operator =
    FactProvenance(..sample_provenance(), derivation: OperatorProvided)
  operator.derivation |> should.equal(OperatorProvided)

  let unknown = FactProvenance(..sample_provenance(), derivation: Unknown)
  unknown.derivation |> should.equal(Unknown)
}

// ---------------------------------------------------------------------------
// Encode/decode round-trip with provenance
// ---------------------------------------------------------------------------

pub fn encode_decode_with_provenance_test() {
  let prov = sample_provenance()
  let fact = make_fact_with_provenance("fp-001", "rent", "EUR 1800", Some(prov))

  let encoded = json.to_string(facts_log.encode_fact(fact))
  let assert Ok(decoded) = json.parse(encoded, facts_log.fact_decoder())

  decoded.fact_id |> should.equal("fp-001")
  decoded.key |> should.equal("rent")
  decoded.value |> should.equal("EUR 1800")
  decoded.confidence |> should.equal(0.85)

  let assert Some(dec_prov) = decoded.provenance
  dec_prov.source_cycle_id |> should.equal("cycle-abc123")
  dec_prov.source_tool |> should.equal("memory_write")
  dec_prov.source_agent |> should.equal("cognitive")
  dec_prov.derivation |> should.equal(Synthesis)
}

pub fn encode_decode_all_derivations_roundtrip_test() {
  let derivations = [DirectObservation, Synthesis, OperatorProvided, Unknown]

  derivations
  |> should.not_equal([])

  // Test each derivation round-trips correctly
  let prov_direct =
    FactProvenance(..sample_provenance(), derivation: DirectObservation)
  let fact_direct =
    make_fact_with_provenance("fp-d", "k", "v", Some(prov_direct))
  let enc_d = json.to_string(facts_log.encode_fact(fact_direct))
  let assert Ok(dec_d) = json.parse(enc_d, facts_log.fact_decoder())
  let assert Some(p_d) = dec_d.provenance
  p_d.derivation |> should.equal(DirectObservation)

  let prov_op =
    FactProvenance(..sample_provenance(), derivation: OperatorProvided)
  let fact_op = make_fact_with_provenance("fp-o", "k", "v", Some(prov_op))
  let enc_o = json.to_string(facts_log.encode_fact(fact_op))
  let assert Ok(dec_o) = json.parse(enc_o, facts_log.fact_decoder())
  let assert Some(p_o) = dec_o.provenance
  p_o.derivation |> should.equal(OperatorProvided)

  let prov_unk = FactProvenance(..sample_provenance(), derivation: Unknown)
  let fact_unk = make_fact_with_provenance("fp-u", "k", "v", Some(prov_unk))
  let enc_u = json.to_string(facts_log.encode_fact(fact_unk))
  let assert Ok(dec_u) = json.parse(enc_u, facts_log.fact_decoder())
  let assert Some(p_u) = dec_u.provenance
  p_u.derivation |> should.equal(Unknown)
}

// ---------------------------------------------------------------------------
// Backward compatibility — legacy facts without provenance
// ---------------------------------------------------------------------------

pub fn decode_legacy_fact_without_provenance_test() {
  // JSON with no "provenance" field at all — simulates legacy data
  let legacy_json =
    "{\"schema_version\":1,\"fact_id\":\"f-legacy\","
    <> "\"timestamp\":\"2026-03-01T10:00:00\","
    <> "\"cycle_id\":\"cycle-old\",\"agent_id\":null,"
    <> "\"key\":\"legacy_key\",\"value\":\"legacy_value\","
    <> "\"scope\":\"persistent\",\"operation\":\"write\","
    <> "\"supersedes\":null,\"confidence\":0.9,\"source\":\"old_tool\"}"

  let assert Ok(decoded) = json.parse(legacy_json, facts_log.fact_decoder())
  decoded.fact_id |> should.equal("f-legacy")
  decoded.key |> should.equal("legacy_key")
  decoded.provenance |> should.equal(None)
}

pub fn decode_fact_with_null_provenance_test() {
  // JSON with explicit null provenance
  let json_with_null =
    "{\"schema_version\":1,\"fact_id\":\"f-null\","
    <> "\"timestamp\":\"2026-03-01T10:00:00\","
    <> "\"cycle_id\":\"cycle-old\",\"agent_id\":null,"
    <> "\"key\":\"null_key\",\"value\":\"null_value\","
    <> "\"scope\":\"session\",\"operation\":\"write\","
    <> "\"supersedes\":null,\"confidence\":0.7,\"source\":\"test\","
    <> "\"provenance\":null}"

  let assert Ok(decoded) = json.parse(json_with_null, facts_log.fact_decoder())
  decoded.fact_id |> should.equal("f-null")
  decoded.provenance |> should.equal(None)
}

// ---------------------------------------------------------------------------
// Encode without provenance (None)
// ---------------------------------------------------------------------------

pub fn encode_decode_without_provenance_test() {
  let fact = make_fact_with_provenance("fp-none", "key", "value", None)
  let encoded = json.to_string(facts_log.encode_fact(fact))
  let assert Ok(decoded) = json.parse(encoded, facts_log.fact_decoder())
  decoded.fact_id |> should.equal("fp-none")
  decoded.provenance |> should.equal(None)
}
