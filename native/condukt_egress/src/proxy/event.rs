//! Wire format for messages between the sidecar and the BEAM-side
//! `Condukt.Sandbox.Net.K8s.ControlBridge`. NDJSON, one frame per
//! line. Tagged with `"type"` so the channel can carry multiple
//! message kinds without ambiguity.
//!
//! Frame kinds:
//!
//!   * `event` — sidecar -> BEAM. A `Condukt.Sandbox.Net.Event`
//!     wrapping a request's lifecycle step.
//!   * `decision_request` — sidecar -> BEAM. Asks the BEAM to make a
//!     policy decision about a request the sidecar is about to
//!     forward. The sidecar holds the connection until a `decision`
//!     comes back (or its `decide_timeout` fires).
//!   * `decision` — BEAM -> sidecar. The decision the sidecar was
//!     waiting on, keyed by `id`.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;

#[allow(clippy::enum_variant_names)]
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    RequestOpened,
    RequestClosed,
    RequestAllowed,
    RequestDenied,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub id: String,
    pub session_id: Option<String>,
    pub host: String,
    pub port: u16,
    pub remote_addr: Option<String>,
    pub scheme: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_headers: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response_status: Option<i32>,
    #[serde(default)]
    pub bytes_in: u64,
    #[serde(default)]
    pub bytes_out: u64,
    pub started_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
}

impl Request {
    pub fn new(
        host: String,
        port: u16,
        remote: Option<SocketAddr>,
        session_id: Option<String>,
    ) -> Self {
        Request {
            id: uuid::Uuid::new_v4().to_string(),
            session_id,
            host,
            port,
            remote_addr: remote.map(|a| a.to_string()),
            scheme: if port == 443 {
                "https".into()
            } else {
                "http".into()
            },
            method: None,
            path: None,
            request_headers: None,
            response_status: None,
            bytes_in: 0,
            bytes_out: 0,
            started_at: Utc::now(),
            finished_at: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub kind: Kind,
    pub request: Request,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub at: DateTime<Utc>,
}

impl Event {
    pub fn new(kind: Kind, request: Request) -> Self {
        Event {
            kind,
            request,
            reason: None,
            at: Utc::now(),
        }
    }

    pub fn with_reason(mut self, reason: impl Into<String>) -> Self {
        self.reason = Some(reason.into());
        self
    }
}

/// Tagged outbound frame sent from the sidecar to the BEAM.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Outbound {
    Event(Box<Event>),
    DecisionRequest {
        id: String,
        session_id: Option<String>,
        host: String,
        port: u16,
        scheme: String,
    },
}

/// Tagged inbound frame received from the BEAM. Currently only
/// `decision` is meaningful; additional shapes can be added without
/// breaking existing senders thanks to `#[serde(other)]` on the
/// fallthrough variant.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Inbound {
    Decision {
        id: String,
        action: DecisionAction,
        #[serde(default)]
        reason: Option<String>,
    },
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DecisionAction {
    Allow,
    Deny,
}
