import gleam/string
import gleeunit/should
import narrative/redactor

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

// API key tests

pub fn redact_anthropic_key_test() {
  let input = "Using key sk-ant-api03-abcdefghijklmnopqrstuvwxyz in request"
  let result = redactor.redact(input)
  should.be_true(!contains(result, "sk-ant-"))
  should.be_true(contains(result, "[REDACTED:api_key]"))
}

pub fn redact_openai_key_test() {
  let input = "key: sk-proj-1234567890abcdefghij"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:api_key]"))
}

pub fn redact_github_token_test() {
  let input = "token ghp_ABCDEFGHIJKLMNOPQRSTUVWXyz12"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:api_key]"))
}

pub fn redact_slack_token_test() {
  let input = "xoxb-1234567890-abcdefghijklmnopqrst"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:api_key]"))
}

pub fn redact_google_api_key_test() {
  let input = "AIzaSyAbcdefghijklmnopqrstuvwxyz12345"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:api_key]"))
}

// JSON field test

pub fn redact_json_api_key_field_test() {
  let input = "{\"api_key\": \"some-very-long-secret-value-here-1234\"}"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:api_key]"))
  should.be_true(!contains(result, "some-very-long"))
}

// Bearer token test

pub fn redact_bearer_token_test() {
  let input =
    "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.abc.def"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:"))
}

// URL credentials test

pub fn redact_url_credentials_test() {
  let input = "postgres://admin:s3cret_p@ss@db.example.com:5432/mydb"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:url_credential]"))
  should.be_true(!contains(result, "s3cret_p@ss"))
  should.be_true(contains(result, "db.example.com"))
}

// Password field test

pub fn redact_password_json_field_test() {
  let input = "{\"password\": \"hunter2\", \"username\": \"admin\"}"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:password]"))
  should.be_true(contains(result, "admin"))
}

// Private key test

pub fn redact_private_key_test() {
  let input =
    "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:private_key]"))
  should.be_true(!contains(result, "MIIE"))
}

// JWT test

pub fn redact_jwt_token_test() {
  let input =
    "token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:jwt]"))
  should.be_true(!contains(result, "eyJhbGci"))
}

// Env secret tests

pub fn redact_env_api_key_test() {
  let input = "OPENAI_API_KEY=sk-1234567890abcdef"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:"))
}

pub fn redact_env_token_test() {
  let input = "AUTH_TOKEN=abc123def456"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:env_secret]"))
}

pub fn redact_env_password_test() {
  let input = "DB_PASSWORD=mysecretpassword"
  let result = redactor.redact(input)
  should.be_true(contains(result, "[REDACTED:env_secret]"))
}

// Idempotent test

pub fn redact_already_redacted_test() {
  let input = "key is [REDACTED:api_key] and token is [REDACTED:bearer_token]"
  let result = redactor.redact(input)
  should.equal(result, input)
}

// No false positives test

pub fn redact_no_false_positives_test() {
  let input = "The color is red and mode=production and count=42"
  let result = redactor.redact(input)
  should.equal(result, input)
}
