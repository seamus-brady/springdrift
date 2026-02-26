import gleam/string
import gleeunit
import gleeunit/should
import llm/adapters/mock
import query_complexity.{Complex, Simple}

pub fn main() -> Nil {
  gleeunit.main()
}

// Provider that always errors, forcing the heuristic fallback path.
fn err_prov() {
  mock.provider_with_error("forced heuristic fallback")
}

// ---------------------------------------------------------------------------
// LLM classification path
// ---------------------------------------------------------------------------

pub fn llm_returns_simple_test() {
  let p = mock.provider_with_text("simple")
  query_complexity.classify("What is 2 + 2?", p, "test-model")
  |> should.equal(Simple)
}

pub fn llm_returns_complex_test() {
  let p = mock.provider_with_text("complex")
  query_complexity.classify("What is 2 + 2?", p, "test-model")
  |> should.equal(Complex)
}

pub fn llm_returns_verbose_response_with_complex_test() {
  // Model says more than one word but response contains "complex"
  let p = mock.provider_with_text("This is a complex query.")
  query_complexity.classify("Hi", p, "test-model")
  |> should.equal(Complex)
}

pub fn llm_returns_unrecognised_falls_back_to_heuristic_test() {
  // Unrecognised response → heuristic → Simple (short, no keywords)
  let p = mock.provider_with_text("I am unable to classify this")
  query_complexity.classify("Hello!", p, "test-model")
  |> should.equal(Simple)
}

pub fn llm_error_falls_back_to_heuristic_simple_test() {
  query_complexity.classify("Hello!", err_prov(), "m")
  |> should.equal(Simple)
}

pub fn llm_error_falls_back_to_heuristic_complex_test() {
  query_complexity.classify(string.repeat("a", 201), err_prov(), "m")
  |> should.equal(Complex)
}

// ---------------------------------------------------------------------------
// Heuristic fallback — Simple queries
// ---------------------------------------------------------------------------

pub fn short_factual_question_is_simple_test() {
  query_complexity.classify("What is the capital of France?", err_prov(), "m")
  |> should.equal(Simple)
}

pub fn short_greeting_is_simple_test() {
  query_complexity.classify("Hello!", err_prov(), "m")
  |> should.equal(Simple)
}

pub fn short_math_is_simple_test() {
  query_complexity.classify("What is 2 + 2?", err_prov(), "m")
  |> should.equal(Simple)
}

// ---------------------------------------------------------------------------
// Heuristic fallback — Complex by length
// ---------------------------------------------------------------------------

pub fn long_message_over_200_chars_is_complex_test() {
  let long_query = string.repeat("a", 201)
  query_complexity.classify(long_query, err_prov(), "m")
  |> should.equal(Complex)
}

pub fn exactly_200_chars_is_simple_test() {
  let boundary = string.repeat("a", 200)
  query_complexity.classify(boundary, err_prov(), "m")
  |> should.equal(Simple)
}

// ---------------------------------------------------------------------------
// Heuristic fallback — Complex by keyword
// ---------------------------------------------------------------------------

pub fn explain_keyword_is_complex_test() {
  query_complexity.classify(
    "Can you explain how recursion works?",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn compare_keyword_is_complex_test() {
  query_complexity.classify("Compare REST and GraphQL", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn analyze_keyword_is_complex_test() {
  query_complexity.classify("Analyze this code snippet", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn analyse_uk_spelling_is_complex_test() {
  query_complexity.classify("Please analyse the data", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn design_keyword_is_complex_test() {
  query_complexity.classify("Design a database schema", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn implement_keyword_is_complex_test() {
  query_complexity.classify(
    "How would I implement a binary tree?",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn architecture_keyword_is_complex_test() {
  query_complexity.classify(
    "What is microservices architecture?",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn trade_off_hyphen_is_complex_test() {
  query_complexity.classify(
    "What are the trade-off considerations?",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn trade_off_space_is_complex_test() {
  query_complexity.classify(
    "Discuss the trade off between speed and memory",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn pros_and_cons_is_complex_test() {
  query_complexity.classify(
    "What are the pros and cons of using Rust?",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn step_by_step_is_complex_test() {
  query_complexity.classify("Give me a step by step guide", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn comprehensive_is_complex_test() {
  query_complexity.classify("Write a comprehensive overview", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn in_depth_hyphen_is_complex_test() {
  query_complexity.classify("Give me an in-depth explanation", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn in_depth_space_is_complex_test() {
  query_complexity.classify("Provide an in depth analysis", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn write_a_is_complex_test() {
  query_complexity.classify("Write a function to sort a list", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn create_a_is_complex_test() {
  query_complexity.classify("Create a REST API endpoint", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn build_a_is_complex_test() {
  query_complexity.classify("Build a simple web server", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn refactor_keyword_is_complex_test() {
  query_complexity.classify(
    "Refactor this function to be cleaner",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn debug_keyword_is_complex_test() {
  query_complexity.classify("Debug this error in my code", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn optimize_keyword_is_complex_test() {
  query_complexity.classify("Optimize this SQL query", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn evaluate_keyword_is_complex_test() {
  query_complexity.classify(
    "Evaluate the performance of this approach",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn assess_keyword_is_complex_test() {
  query_complexity.classify("Assess the security risks", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn prove_keyword_is_complex_test() {
  query_complexity.classify(
    "Prove that this algorithm is correct",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn derive_keyword_is_complex_test() {
  query_complexity.classify(
    "Derive the formula for compound interest",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn case_insensitive_keyword_test() {
  query_complexity.classify("EXPLAIN how this works", err_prov(), "m")
  |> should.equal(Complex)
}

// ---------------------------------------------------------------------------
// Heuristic fallback — Complex by multiple question marks
// ---------------------------------------------------------------------------

pub fn two_question_marks_is_complex_test() {
  query_complexity.classify(
    "What is X? And how does it relate to Y?",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn three_question_marks_is_complex_test() {
  query_complexity.classify("Why? When? How?", err_prov(), "m")
  |> should.equal(Complex)
}

pub fn one_question_mark_is_simple_test() {
  query_complexity.classify("What time is it?", err_prov(), "m")
  |> should.equal(Simple)
}

// ---------------------------------------------------------------------------
// Heuristic fallback — Complex by numbered list
// ---------------------------------------------------------------------------

pub fn numbered_list_dot_is_complex_test() {
  query_complexity.classify(
    "Here are the steps:\n1. First do this\n2. Then that",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}

pub fn numbered_list_paren_is_complex_test() {
  query_complexity.classify(
    "Steps: 1) open the file 2) read the data",
    err_prov(),
    "m",
  )
  |> should.equal(Complex)
}
