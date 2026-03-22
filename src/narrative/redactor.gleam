//// Redactor — pure secret-redaction module.
////
//// Applies regex patterns at log write boundaries to scrub secrets before
//// they reach persistent storage. Idempotent — already-redacted text
//// passes through unchanged.

@external(erlang, "springdrift_ffi", "re_replace_all")
fn re_replace_all(text: String, pattern: String, replacement: String) -> String

/// Redact secrets from text by applying all pattern categories in sequence.
/// Returns the text with secrets replaced by `[REDACTED:<type>]` markers.
pub fn redact(text: String) -> String {
  text
  |> redact_private_keys
  |> redact_jwts
  |> redact_api_keys
  |> redact_bearer_tokens
  |> redact_url_credentials
  |> redact_password_fields
  |> redact_env_secrets
}

// ---------------------------------------------------------------------------
// Pattern categories
// ---------------------------------------------------------------------------

/// Private key blocks: -----BEGIN ... PRIVATE KEY----- ... -----END ... PRIVATE KEY-----
fn redact_private_keys(text: String) -> String {
  re_replace_all(
    text,
    "-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----",
    "[REDACTED:private_key]",
  )
}

/// JWT tokens: eyJ...<base64>.<base64>.<base64>
fn redact_jwts(text: String) -> String {
  re_replace_all(
    text,
    "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+",
    "[REDACTED:jwt]",
  )
}

/// API keys by prefix: sk-ant-, sk-, ghp_, xoxb-, AIza
/// Also catches JSON fields specifically named for secrets with long opaque values.
/// Note: "key" and "token" alone are too generic (matches memory_write "key" param,
/// "tokens_used" context, etc.). Only match compound names that imply secrets.
fn redact_api_keys(text: String) -> String {
  // Known prefixes (word boundary prevents matching inside words like "task-...")
  let t1 =
    re_replace_all(text, "\\bsk-ant-[A-Za-z0-9_-]{20,}", "[REDACTED:api_key]")
  let t2 = re_replace_all(t1, "\\bsk-[A-Za-z0-9_-]{20,}", "[REDACTED:api_key]")
  let t3 = re_replace_all(t2, "ghp_[A-Za-z0-9]{20,}", "[REDACTED:api_key]")
  let t4 = re_replace_all(t3, "xoxb-[A-Za-z0-9-]{20,}", "[REDACTED:api_key]")
  let t5 = re_replace_all(t4, "AIza[A-Za-z0-9_-]{20,}", "[REDACTED:api_key]")
  // JSON fields with secret-specific names only (not generic "key" or "token")
  re_replace_all(
    t5,
    "\"(?:secret|apikey|api_key|access_token|auth_token|refresh_token|client_secret|private_key)\"\\s*:\\s*\"[^\"]{20,}\"",
    "\"[REDACTED:api_key]\"",
  )
}

/// Bearer tokens: Authorization: Bearer <token>
fn redact_bearer_tokens(text: String) -> String {
  re_replace_all(text, "Bearer [^\\s\"]{20,}", "Bearer [REDACTED:bearer_token]")
}

/// URL credentials: ://user:password@host
fn redact_url_credentials(text: String) -> String {
  re_replace_all(text, "://[^:@/]+:[^@]+@", "://[REDACTED:url_credential]@")
}

/// Password fields in JSON: "password": "...", "passwd": "...", etc.
fn redact_password_fields(text: String) -> String {
  re_replace_all(
    text,
    "\"(?:password|passwd|pass|secret|credential)\"\\s*:\\s*\"[^\"]*\"",
    "\"[REDACTED:password]\"",
  )
}

/// Environment secret assignments: API_KEY=value, AUTH_TOKEN=value, DB_PASS=value
/// Requires underscore prefix (_KEY, _PASS) to avoid false positives on PRIMARY_KEY, CACHE_KEY
fn redact_env_secrets(text: String) -> String {
  re_replace_all(
    text,
    "(?:SECRET|TOKEN|PASSWORD|_KEY|_PASS)[\\s]*[=:][\\s]*\\S+",
    "[REDACTED:env_secret]",
  )
}
