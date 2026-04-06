//// Communications types — messages, channels, delivery status, config.
////
//// Designed for email via AgentMail. The CommsChannel variant type is
//// the extensibility point for future channels (WhatsApp, Slack, etc).

// Copyright (C) 2026 Seamus Brady <seamus@corvideon.ie>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Channel
// ---------------------------------------------------------------------------

pub type CommsChannel {
  Email
  // Future: WhatsApp, Slack, SMS
}

// ---------------------------------------------------------------------------
// Message
// ---------------------------------------------------------------------------

pub type CommsMessage {
  CommsMessage(
    message_id: String,
    thread_id: String,
    channel: CommsChannel,
    direction: Direction,
    from: String,
    to: String,
    subject: String,
    body_text: String,
    timestamp: String,
    status: DeliveryStatus,
    cycle_id: Option(String),
  )
}

pub type Direction {
  Inbound
  Outbound
}

pub type DeliveryStatus {
  Sent
  Delivered
  Failed(reason: String)
  Pending
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

pub type CommsConfig {
  CommsConfig(
    enabled: Bool,
    inbox_id: String,
    api_key_env: String,
    from_address: String,
    allowed_recipients: List(String),
    from_name: String,
    max_outbound_per_hour: Int,
  )
}
