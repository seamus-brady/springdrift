//// Communications types — messages, channels, delivery status, config.
////
//// Designed for email via AgentMail. The CommsChannel variant type is
//// the extensibility point for future channels (WhatsApp, Slack, etc).

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
    allowed_recipients: List(String),
    from_name: String,
    max_outbound_per_hour: Int,
  )
}
