import facts/log as facts_log
import facts/types.{
  type MemoryFact, Clear, Ephemeral, MemoryFact, Persistent, Session, Superseded,
  Write,
}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  let dir = "/tmp/facts_log_test_" <> suffix
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

fn make_fact(fact_id: String, key: String, value: String) -> MemoryFact {
  MemoryFact(
    schema_version: 1,
    fact_id:,
    timestamp: "2026-03-08T10:00:00",
    cycle_id: "cycle-001",
    agent_id: None,
    key:,
    value:,
    scope: Session,
    operation: Write,
    supersedes: None,
    confidence: 0.9,
    source: "cognitive_loop",
    provenance: None,
  )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn encode_decode_roundtrip_test() {
  let fact = make_fact("fact-001", "dublin_rent", "€2,340/month")
  let encoded = json.to_string(facts_log.encode_fact(fact))
  let assert Ok(decoded) = json.parse(encoded, facts_log.fact_decoder())
  decoded.fact_id |> should.equal("fact-001")
  decoded.key |> should.equal("dublin_rent")
  decoded.value |> should.equal("€2,340/month")
  decoded.confidence |> should.equal(0.9)
  decoded.source |> should.equal("cognitive_loop")
}

pub fn scope_encoding_test() {
  let persistent = MemoryFact(..make_fact("f1", "k1", "v1"), scope: Persistent)
  let session = MemoryFact(..make_fact("f2", "k2", "v2"), scope: Session)
  let ephemeral = MemoryFact(..make_fact("f3", "k3", "v3"), scope: Ephemeral)

  let enc_p = json.to_string(facts_log.encode_fact(persistent))
  let assert Ok(dec_p) = json.parse(enc_p, facts_log.fact_decoder())
  dec_p.scope |> should.equal(Persistent)

  let enc_s = json.to_string(facts_log.encode_fact(session))
  let assert Ok(dec_s) = json.parse(enc_s, facts_log.fact_decoder())
  dec_s.scope |> should.equal(Session)

  let enc_e = json.to_string(facts_log.encode_fact(ephemeral))
  let assert Ok(dec_e) = json.parse(enc_e, facts_log.fact_decoder())
  dec_e.scope |> should.equal(Ephemeral)
}

pub fn operation_encoding_test() {
  let write = MemoryFact(..make_fact("f1", "k1", "v1"), operation: Write)
  let clear = MemoryFact(..make_fact("f2", "k2", "v2"), operation: Clear)
  let superseded =
    MemoryFact(
      ..make_fact("f3", "k3", "v3"),
      operation: Superseded,
      supersedes: Some("f1"),
    )

  let enc_w = json.to_string(facts_log.encode_fact(write))
  let assert Ok(dec_w) = json.parse(enc_w, facts_log.fact_decoder())
  dec_w.operation |> should.equal(Write)

  let enc_c = json.to_string(facts_log.encode_fact(clear))
  let assert Ok(dec_c) = json.parse(enc_c, facts_log.fact_decoder())
  dec_c.operation |> should.equal(Clear)

  let enc_s = json.to_string(facts_log.encode_fact(superseded))
  let assert Ok(dec_s) = json.parse(enc_s, facts_log.fact_decoder())
  dec_s.operation |> should.equal(Superseded)
  dec_s.supersedes |> should.equal(Some("f1"))
}

pub fn load_all_empty_test() {
  let dir = test_dir("empty")
  let facts = facts_log.load_all(dir)
  facts |> should.equal([])
}

pub fn load_all_nonexistent_test() {
  let facts = facts_log.load_all("/tmp/facts_nonexistent_xyz")
  facts |> should.equal([])
}

pub fn write_and_load_test() {
  let dir = test_dir("write_load")
  let f1 = make_fact("fact-wl1", "rent", "2340")
  let f2 = make_fact("fact-wl2", "population", "1.4M")

  let json1 = json.to_string(facts_log.encode_fact(f1))
  let json2 = json.to_string(facts_log.encode_fact(f2))
  let _ =
    simplifile.write(dir <> "/facts.jsonl", json1 <> "\n" <> json2 <> "\n")

  let facts = facts_log.load_all(dir)
  list.length(facts) |> should.equal(2)
}

pub fn resolve_current_simple_test() {
  let dir = test_dir("resolve_simple")
  let f1 = make_fact("fact-r1", "rent", "2340")
  let f2 = make_fact("fact-r2", "population", "1.4M")

  let json1 = json.to_string(facts_log.encode_fact(f1))
  let json2 = json.to_string(facts_log.encode_fact(f2))
  let _ =
    simplifile.write(dir <> "/facts.jsonl", json1 <> "\n" <> json2 <> "\n")

  let current = facts_log.resolve_current(dir, None)
  list.length(current) |> should.equal(2)
}

pub fn resolve_current_overwrites_same_key_test() {
  let f1 = make_fact("fact-o1", "rent", "2340")
  let f2 =
    MemoryFact(..make_fact("fact-o2", "rent", "2500"), fact_id: "fact-o2")

  let current = facts_log.resolve_from_list([f1, f2], None)
  list.length(current) |> should.equal(1)
  let assert [latest] = current
  latest.value |> should.equal("2500")
  latest.fact_id |> should.equal("fact-o2")
}

pub fn resolve_current_clear_removes_key_test() {
  let f1 = make_fact("fact-c1", "rent", "2340")
  let f2 =
    MemoryFact(
      ..make_fact("fact-c2", "rent", ""),
      fact_id: "fact-c2",
      operation: Clear,
    )

  let current = facts_log.resolve_from_list([f1, f2], None)
  list.length(current) |> should.equal(0)
}

pub fn resolve_current_scope_filter_test() {
  let f1 =
    MemoryFact(..make_fact("fact-sf1", "rent", "2340"), scope: Persistent)
  let f2 = MemoryFact(..make_fact("fact-sf2", "temp", "22C"), scope: Session)

  let persistent = facts_log.resolve_from_list([f1, f2], Some(Persistent))
  list.length(persistent) |> should.equal(1)
  let assert [p] = persistent
  p.key |> should.equal("rent")

  let session = facts_log.resolve_from_list([f1, f2], Some(Session))
  list.length(session) |> should.equal(1)
  let assert [s] = session
  s.key |> should.equal("temp")
}

pub fn trace_key_test() {
  let dir = test_dir("trace")
  let f1 = make_fact("fact-t1", "rent", "2340")
  let f2 =
    MemoryFact(..make_fact("fact-t2", "rent", "2500"), fact_id: "fact-t2")
  let f3 = make_fact("fact-t3", "population", "1.4M")

  let lines =
    [f1, f2, f3]
    |> list.map(fn(f) { json.to_string(facts_log.encode_fact(f)) })
    |> list.map(fn(s) { s <> "\n" })
  let content =
    lines
    |> list.fold("", fn(acc, line) { acc <> line })
  let _ = simplifile.write(dir <> "/facts.jsonl", content)

  let history = facts_log.trace_key(dir, "rent")
  list.length(history) |> should.equal(2)

  let other = facts_log.trace_key(dir, "population")
  list.length(other) |> should.equal(1)

  let none = facts_log.trace_key(dir, "nonexistent")
  list.length(none) |> should.equal(0)
}

pub fn lenient_decoder_null_fields_test() {
  let minimal =
    "{\"fact_id\":\"f-min\",\"timestamp\":\"2026-03-08T10:00:00\","
    <> "\"key\":\"test_key\","
    <> "\"schema_version\":null,\"cycle_id\":null,\"agent_id\":null,"
    <> "\"value\":null,\"scope\":null,\"operation\":null,"
    <> "\"supersedes\":null,\"confidence\":null,\"source\":null}"
  let assert Ok(decoded) = json.parse(minimal, facts_log.fact_decoder())
  decoded.fact_id |> should.equal("f-min")
  decoded.key |> should.equal("test_key")
  decoded.schema_version |> should.equal(1)
  decoded.cycle_id |> should.equal("")
  decoded.agent_id |> should.equal(None)
  decoded.value |> should.equal("")
  decoded.scope |> should.equal(Session)
  decoded.operation |> should.equal(Write)
  decoded.supersedes |> should.equal(None)
  decoded.confidence |> should.equal(0.0)
  decoded.source |> should.equal("")
  decoded.provenance |> should.equal(None)
}
