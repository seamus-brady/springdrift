# OAuth / OIDC Authentication — Specification

**Status**: Planned
**Date**: 2026-03-26
**Dependencies**: Multi-tenant (planned), Web GUI v2 (planned)

---

## Table of Contents

- [Overview](#overview)
- [Current State](#current-state)
- [Supported Providers](#supported-providers)
- [Authentication Flow](#authentication-flow)
  - [Web GUI Login](#web-gui-login)
  - [Token Exchange](#token-exchange)
  - [Session Management](#session-management)
- [Provider Configuration](#provider-configuration)
  - [Google Workspace](#google-workspace)
  - [Microsoft Entra ID](#microsoft-entra-id)
  - [Generic OIDC](#generic-oidc)
  - [Corporate SAML (via OIDC bridge)](#corporate-saml-via-oidc-bridge)
- [User Mapping](#user-mapping)
  - [Auto-Provisioning](#auto-provisioning)
  - [Domain Restriction](#domain-restriction)
  - [Role Mapping](#role-mapping)
  - [Tenant Mapping](#tenant-mapping)
- [API Authentication](#api-authentication)
  - [Web GUI (browser)](#web-gui-browser)
  - [A2A Endpoints](#a2a-endpoints)
  - [SD Tooling (CLI)](#sd-tooling-cli)
- [Architecture](#architecture)
  - [Auth Module](#auth-module)
  - [Session Store](#session-store)
  - [Login Page](#login-page)
- [Backward Compatibility](#backward-compatibility)
- [D' Integration](#d-integration)
- [Multi-Tenant Integration](#multi-tenant-integration)
- [Configuration](#configuration)
- [Security](#security)
- [Relationship to Other Specs](#relationship-to-other-specs)
- [Implementation Order](#implementation-order)

---

## Overview

Replace the current bearer token authentication (`SPRINGDRIFT_WEB_TOKEN`) with OAuth 2.0 / OpenID Connect, supporting Google Workspace and Microsoft Entra ID (Azure AD) as identity providers. Enables enterprise SSO — operators log in with their existing corporate credentials.

The bearer token remains as a fallback for development, CLI tools, and environments without OAuth.

---

## Current State

Authentication is a single static token set via environment variable:

```sh
export SPRINGDRIFT_WEB_TOKEN="some-secret"
```

Every HTTP and WebSocket request must include `Authorization: Bearer <token>` or `?token=` query parameter. No user identity, no session management, no SSO.

---

## Supported Providers

| Provider | Protocol | Use Case |
|---|---|---|
| **Google Workspace** | OIDC | Organisations using Google for email/identity |
| **Microsoft Entra ID** | OIDC | Organisations using Microsoft 365 / Azure AD |
| **Generic OIDC** | OIDC | Any OIDC-compliant identity provider (Okta, Auth0, Keycloak, etc.) |
| **Bearer token** | Static token | Development, CLI tools, backward compatibility |

---

## Authentication Flow

### Web GUI Login

```
1. User navigates to Springdrift web GUI
2. Not authenticated → redirect to login page
3. Login page shows: [Sign in with Google] [Sign in with Microsoft]
   (Or just one, depending on config)
4. User clicks provider button
5. Redirect to provider's OAuth consent screen
6. User authenticates with their corporate credentials
7. Provider redirects back to Springdrift with authorization code
8. Springdrift exchanges code for tokens (server-side)
9. Springdrift verifies ID token, extracts user info
10. Creates session, sets secure cookie
11. Redirect to the web GUI
```

### Token Exchange

Server-side OAuth 2.0 authorization code flow (not implicit — no tokens in browser URLs):

```gleam
pub type OAuthCallback {
  OAuthCallback(
    code: String,              // Authorization code from provider
    state: String,             // CSRF protection nonce
  )
}

pub type OAuthTokens {
  OAuthTokens(
    access_token: String,      // For API calls to the provider
    id_token: String,          // JWT with user identity claims
    refresh_token: Option(String),
    expires_in: Int,
  )
}

pub type UserInfo {
  UserInfo(
    email: String,
    name: String,
    picture: Option(String),   // Avatar URL
    provider: String,          // "google" | "microsoft" | "oidc"
    provider_user_id: String,  // Unique ID from the provider
  )
}
```

### Session Management

After successful OAuth, a session is created:

```gleam
pub type Session {
  Session(
    session_id: String,        // Random token, stored in secure cookie
    user_info: UserInfo,
    tenant_id: String,         // Resolved from user mapping
    role: UserRole,            // admin | member
    created_at: String,
    expires_at: String,        // Session expiry (configurable, default 24h)
    last_activity: String,     // Updated on each request
  )
}
```

Sessions stored in ETS (in-memory, fast lookup). Lost on restart — users simply re-authenticate. No sensitive data persisted to disk.

Session cookies:
- `HttpOnly` — not accessible to JavaScript
- `Secure` — only sent over HTTPS
- `SameSite=Lax` — CSRF protection
- Short-lived (configurable, default 24 hours)
- Idle timeout (configurable, default 2 hours) — session expires if no activity

---

## Provider Configuration

### Google Workspace

```toml
[auth.google]
enabled = true
client_id = "123456789.apps.googleusercontent.com"
client_secret_env = "GOOGLE_OAUTH_CLIENT_SECRET"    # Env var, never in config
allowed_domains = ["lawfirm.com"]                    # Restrict to corporate domain
```

Setup:
1. Create OAuth app in Google Cloud Console
2. Set authorized redirect URI: `https://agent.example.com/auth/callback/google`
3. Set client ID in config, client secret in env var

### Microsoft Entra ID

```toml
[auth.microsoft]
enabled = true
tenant_id = "your-entra-tenant-id"                   # Or "common" for multi-tenant
client_id = "your-app-client-id"
client_secret_env = "MICROSOFT_OAUTH_CLIENT_SECRET"
allowed_domains = ["lawfirm.com"]
```

Setup:
1. Register app in Azure Portal → App registrations
2. Set redirect URI: `https://agent.example.com/auth/callback/microsoft`
3. Grant `openid`, `profile`, `email` permissions
4. Set client ID and tenant ID in config, client secret in env var

### Generic OIDC

For Okta, Auth0, Keycloak, or any OIDC-compliant provider:

```toml
[auth.oidc]
enabled = true
issuer = "https://auth.example.com"                  # OIDC discovery URL
client_id = "springdrift-app"
client_secret_env = "OIDC_CLIENT_SECRET"
scopes = ["openid", "profile", "email"]
allowed_domains = []                                  # Empty = allow all authenticated users
```

Springdrift discovers endpoints automatically from `{issuer}/.well-known/openid-configuration`.

### Corporate SAML (via OIDC bridge)

Many enterprises use SAML (Active Directory Federation Services, Shibboleth). Rather than implementing SAML directly, these organisations can use:
- Microsoft Entra ID as the OIDC bridge (ADFS → Entra → Springdrift)
- Keycloak as the OIDC bridge (SAML IdP → Keycloak → Springdrift)
- Auth0 enterprise connections

Springdrift speaks OIDC only. The bridge is the customer's responsibility. This keeps the implementation simple and standards-compliant.

---

## User Mapping

### Auto-Provisioning

When a user authenticates for the first time, they can be auto-provisioned:

```toml
[auth]
auto_provision = true                    # Create user entry on first login
default_role = "member"                  # New users get member role
default_tenant = "default"               # New users assigned to default tenant
```

Or disabled — only pre-registered users in `tenants.toml` can log in:

```toml
[auth]
auto_provision = false                   # Only existing users can log in
```

### Domain Restriction

Restrict authentication to specific email domains:

```toml
[auth.google]
allowed_domains = ["lawfirm.com", "partner-firm.com"]
```

Users with `@lawfirm.com` and `@partner-firm.com` emails can log in. All others are rejected after OAuth — they authenticate with Google but Springdrift denies access.

### Role Mapping

Map provider attributes to Springdrift roles:

```toml
[auth.roles]
# Users with these emails get admin role
admins = ["alice@lawfirm.com", "bob@lawfirm.com"]

# Or by provider group (Microsoft Entra groups)
admin_groups = ["Springdrift-Admins"]

# Everyone else gets member role
default = "member"
```

### Tenant Mapping

Map users to tenants based on email domain or explicit mapping:

```toml
[auth.tenants]
# By domain
"lawfirm.com" = "legal-team"
"partner-firm.com" = "partner-access"

# By individual email (overrides domain mapping)
"alice@lawfirm.com" = "admin-workspace"
```

See: [Multi-Tenant spec](multi-tenant.md)

---

## API Authentication

### Web GUI (browser)

OAuth flow as described above. Session cookie sent with every request. WebSocket upgrade includes the session cookie.

### A2A Endpoints

External agents authenticate via bearer tokens (not OAuth):

```toml
[[a2a.agents]]
name = "external-agent"
token = "a2a-secret-token"              # Or token_env = "A2A_EXTERNAL_TOKEN"
```

A2A doesn't need user identity — it needs service identity. Bearer tokens are appropriate here.

See: [External Agent Integration spec](external-agent-integration.md)

### SD Tooling (CLI)

SD Audit, SD Budget, SD Backup run offline against files — no authentication needed.

For future features that need live access (e.g. SD Audit querying the running agent), the CLI tools use:

```sh
# Device flow (for terminal-based OAuth)
sd-audit login
# Opens browser for OAuth, stores token locally
# Or:
sd-audit --token <bearer-token>
```

---

## Architecture

### Auth Module

```
web/auth.gleam               — Current bearer token auth (preserved)
web/oauth.gleam               — OAuth 2.0 / OIDC implementation
web/oauth/google.gleam        — Google-specific endpoints and claims
web/oauth/microsoft.gleam     — Microsoft-specific endpoints and claims
web/oauth/oidc.gleam          — Generic OIDC discovery and flow
web/session.gleam             — Session creation, validation, expiry
```

### Session Store

ETS table owned by the web server process:

```gleam
pub type SessionStore {
  SessionStore(
    table: Dynamic,                     // ETS table
    expiry_ms: Int,                     // Session lifetime
    idle_timeout_ms: Int,               // Inactivity timeout
  )
}
```

Operations:
- `create_session(user_info, tenant_id, role) -> Session`
- `validate_session(session_id) -> Result(Session, Nil)`
- `touch_session(session_id)` — update last_activity
- `destroy_session(session_id)` — logout
- `cleanup_expired()` — periodic sweep (on timer)

### Login Page

A simple HTML page served at `/login`:

```
┌──────────────────────────────────────┐
│                                      │
│         Springdrift                   │
│                                      │
│   ┌──────────────────────────────┐   │
│   │  ▶ Sign in with Google       │   │
│   └──────────────────────────────┘   │
│                                      │
│   ┌──────────────────────────────┐   │
│   │  ▶ Sign in with Microsoft    │   │
│   └──────────────────────────────┘   │
│                                      │
│   ─────── or ───────                 │
│                                      │
│   Token: [________________] [Go]     │
│                                      │
└──────────────────────────────────────┘
```

The token field is for development/fallback. In production with OAuth configured, it can be hidden.

### HTTP Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/login` | Login page |
| GET | `/auth/google` | Initiate Google OAuth flow |
| GET | `/auth/microsoft` | Initiate Microsoft OAuth flow |
| GET | `/auth/oidc` | Initiate generic OIDC flow |
| GET | `/auth/callback/google` | Google OAuth callback |
| GET | `/auth/callback/microsoft` | Microsoft OAuth callback |
| GET | `/auth/callback/oidc` | Generic OIDC callback |
| POST | `/auth/token` | Bearer token login (API/development) |
| POST | `/auth/logout` | Destroy session |
| GET | `/auth/session` | Current session info (for JS) |

---

## Backward Compatibility

| Scenario | Behaviour |
|---|---|
| No `[auth]` config | Bearer token only (current behaviour, `SPRINGDRIFT_WEB_TOKEN`) |
| `[auth.google]` enabled | OAuth + bearer token fallback |
| Both OAuth providers enabled | Login page shows both buttons |
| `auto_provision = false` | Only pre-registered users in `tenants.toml` |
| No `SPRINGDRIFT_WEB_TOKEN` and no OAuth | No auth (development mode) |

Existing installations continue to work unchanged. OAuth is additive.

---

## D' Integration

Authentication is not D'-gated — it happens before the cognitive loop is involved. However:

- The authenticated **user identity** is attached to every `UserInput` message (for audit trail)
- The cycle log records **who** triggered each cycle (email from OAuth claims)
- The D' input gate sees the user identity in context — a future enhancement could weight trust by user role
- The D' output gate sees the user identity — a future enhancement could adjust confidentiality rules per user

---

## Multi-Tenant Integration

OAuth user mapping feeds directly into the multi-tenant routing:

```
User authenticates → email extracted from ID token
  → email domain matched to tenant in [auth.tenants] mapping
  → user role determined from [auth.roles] mapping
  → session created with (user, tenant, role)
  → all requests scoped to that tenant
```

See: [Multi-Tenant spec](multi-tenant.md)

---

## Configuration

```toml
[auth]
# Enable OAuth (default: false — bearer token only)
# enabled = false

# Auto-create user entries on first OAuth login (default: true)
# auto_provision = true

# Default role for new users (default: "member")
# default_role = "member"

# Default tenant for new users (default: "default")
# default_tenant = "default"

# Session lifetime in ms (default: 86400000 = 24h)
# session_expiry_ms = 86400000

# Session idle timeout in ms (default: 7200000 = 2h)
# idle_timeout_ms = 7200000

[auth.google]
# enabled = false
# client_id = ""
# client_secret_env = "GOOGLE_OAUTH_CLIENT_SECRET"
# allowed_domains = []

[auth.microsoft]
# enabled = false
# tenant_id = ""                       # Entra tenant ID or "common"
# client_id = ""
# client_secret_env = "MICROSOFT_OAUTH_CLIENT_SECRET"
# allowed_domains = []

[auth.oidc]
# enabled = false
# issuer = ""                          # OIDC discovery URL
# client_id = ""
# client_secret_env = "OIDC_CLIENT_SECRET"
# scopes = ["openid", "profile", "email"]
# allowed_domains = []

[auth.roles]
# admins = ["alice@example.com"]
# admin_groups = []
# default = "member"

[auth.tenants]
# "example.com" = "default"
```

---

## Security

- **Authorization code flow** — tokens never exposed in browser URLs
- **Server-side token exchange** — client secrets never sent to the browser
- **HttpOnly, Secure, SameSite cookies** — session cookies not accessible to JS, HTTPS only, CSRF protected
- **CSRF state parameter** — random nonce verified on callback
- **ID token verification** — JWT signature verified against provider's JWKS
- **Domain restriction** — only specified email domains can access
- **Session expiry + idle timeout** — automatic logout on inactivity
- **Secrets in env vars** — client secrets never in config files
- **No password storage** — Springdrift never sees or stores user passwords

---

## Relationship to Other Specs

| Spec | Relationship |
|---|---|
| [Multi-Tenant](multi-tenant.md) | OAuth provides user identity → tenant routing |
| [Web GUI v2](web-gui-v2.md) | Login page, session-aware navigation, user avatar display |
| [SD Install](sd-install.md) | OAuth provider configured during deployment |
| [SD Designer](sd-designer.md) | OAuth settings in the design file |
| [Comms Agent](comms-agent.md) | Authenticated user identity in outbound messages |
| [External Agent Integration](external-agent-integration.md) | A2A uses bearer tokens, not OAuth (service-to-service) |
| [Autonomous Endeavours](autonomous-endeavours.md) | User identity on approval gates |
| [Git Backup](git-backup-restore.md) | Session data NOT backed up (ephemeral, in ETS) |
| [SD Audit](sd-audit.md) | Audit can report per-user activity from cycle log user_id field |

---

## Implementation Order

| Phase | What | Effort |
|---|---|---|
| 1 | Session store (ETS) + session cookie management | Small |
| 2 | Login page (HTML) | Small |
| 3 | Google OIDC flow (most common provider) | Medium |
| 4 | Microsoft Entra flow | Medium |
| 5 | Generic OIDC discovery + flow | Medium |
| 6 | User mapping (domain → tenant, email → role) | Small |
| 7 | Auto-provisioning | Small |
| 8 | WebSocket session validation | Small |
| 9 | User identity on cycle log entries | Small |
| 10 | Config parsing + SD Designer integration | Medium |

Phase 1-3 delivers Google SSO. Phase 4 adds Microsoft. Phase 5 adds any OIDC provider. The rest is mapping and integration.
