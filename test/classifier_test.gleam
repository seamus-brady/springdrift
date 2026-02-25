import classifier.{Complex, Simple}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Simple queries
// ---------------------------------------------------------------------------

pub fn short_factual_question_is_simple_test() {
  classifier.classify("What is the capital of France?")
  |> should.equal(Simple)
}

pub fn short_greeting_is_simple_test() {
  classifier.classify("Hello!")
  |> should.equal(Simple)
}

pub fn short_math_is_simple_test() {
  classifier.classify("What is 2 + 2?")
  |> should.equal(Simple)
}

// ---------------------------------------------------------------------------
// Complex by length
// ---------------------------------------------------------------------------

pub fn long_message_over_200_chars_is_complex_test() {
  let long_query = string.repeat("a", 201)
  classifier.classify(long_query)
  |> should.equal(Complex)
}

pub fn exactly_200_chars_is_simple_test() {
  let boundary = string.repeat("a", 200)
  classifier.classify(boundary)
  |> should.equal(Simple)
}

// ---------------------------------------------------------------------------
// Complex by keyword
// ---------------------------------------------------------------------------

pub fn explain_keyword_is_complex_test() {
  classifier.classify("Can you explain how recursion works?")
  |> should.equal(Complex)
}

pub fn compare_keyword_is_complex_test() {
  classifier.classify("Compare REST and GraphQL")
  |> should.equal(Complex)
}

pub fn analyze_keyword_is_complex_test() {
  classifier.classify("Analyze this code snippet")
  |> should.equal(Complex)
}

pub fn analyse_uk_spelling_is_complex_test() {
  classifier.classify("Please analyse the data")
  |> should.equal(Complex)
}

pub fn design_keyword_is_complex_test() {
  classifier.classify("Design a database schema")
  |> should.equal(Complex)
}

pub fn implement_keyword_is_complex_test() {
  classifier.classify("How would I implement a binary tree?")
  |> should.equal(Complex)
}

pub fn architecture_keyword_is_complex_test() {
  classifier.classify("What is microservices architecture?")
  |> should.equal(Complex)
}

pub fn trade_off_hyphen_is_complex_test() {
  classifier.classify("What are the trade-off considerations?")
  |> should.equal(Complex)
}

pub fn trade_off_space_is_complex_test() {
  classifier.classify("Discuss the trade off between speed and memory")
  |> should.equal(Complex)
}

pub fn pros_and_cons_is_complex_test() {
  classifier.classify("What are the pros and cons of using Rust?")
  |> should.equal(Complex)
}

pub fn step_by_step_is_complex_test() {
  classifier.classify("Give me a step by step guide")
  |> should.equal(Complex)
}

pub fn comprehensive_is_complex_test() {
  classifier.classify("Write a comprehensive overview")
  |> should.equal(Complex)
}

pub fn in_depth_hyphen_is_complex_test() {
  classifier.classify("Give me an in-depth explanation")
  |> should.equal(Complex)
}

pub fn in_depth_space_is_complex_test() {
  classifier.classify("Provide an in depth analysis")
  |> should.equal(Complex)
}

pub fn write_a_is_complex_test() {
  classifier.classify("Write a function to sort a list")
  |> should.equal(Complex)
}

pub fn create_a_is_complex_test() {
  classifier.classify("Create a REST API endpoint")
  |> should.equal(Complex)
}

pub fn build_a_is_complex_test() {
  classifier.classify("Build a simple web server")
  |> should.equal(Complex)
}

pub fn refactor_keyword_is_complex_test() {
  classifier.classify("Refactor this function to be cleaner")
  |> should.equal(Complex)
}

pub fn debug_keyword_is_complex_test() {
  classifier.classify("Debug this error in my code")
  |> should.equal(Complex)
}

pub fn optimize_keyword_is_complex_test() {
  classifier.classify("Optimize this SQL query")
  |> should.equal(Complex)
}

pub fn evaluate_keyword_is_complex_test() {
  classifier.classify("Evaluate the performance of this approach")
  |> should.equal(Complex)
}

pub fn assess_keyword_is_complex_test() {
  classifier.classify("Assess the security risks")
  |> should.equal(Complex)
}

pub fn prove_keyword_is_complex_test() {
  classifier.classify("Prove that this algorithm is correct")
  |> should.equal(Complex)
}

pub fn derive_keyword_is_complex_test() {
  classifier.classify("Derive the formula for compound interest")
  |> should.equal(Complex)
}

pub fn case_insensitive_keyword_test() {
  classifier.classify("EXPLAIN how this works")
  |> should.equal(Complex)
}

// ---------------------------------------------------------------------------
// Complex by multiple question marks
// ---------------------------------------------------------------------------

pub fn two_question_marks_is_complex_test() {
  classifier.classify("What is X? And how does it relate to Y?")
  |> should.equal(Complex)
}

pub fn three_question_marks_is_complex_test() {
  classifier.classify("Why? When? How?")
  |> should.equal(Complex)
}

pub fn one_question_mark_is_simple_test() {
  classifier.classify("What time is it?")
  |> should.equal(Simple)
}

// ---------------------------------------------------------------------------
// Complex by numbered list
// ---------------------------------------------------------------------------

pub fn numbered_list_dot_is_complex_test() {
  classifier.classify("Here are the steps:\n1. First do this\n2. Then that")
  |> should.equal(Complex)
}

pub fn numbered_list_paren_is_complex_test() {
  classifier.classify("Steps: 1) open the file 2) read the data")
  |> should.equal(Complex)
}
