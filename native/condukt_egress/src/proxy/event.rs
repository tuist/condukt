//! Wire format for events the sidecar emits back to the BEAM. NDJSON,
//! one event per line, decoded into `Condukt.Sandbox.Net.Request` /
//! `Condukt.Sandbox.Net.Event` on the BEAM side.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
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
#[serde(rename_all = "lowercase")]
pub enum Tier {
    Sni,
    Body,
    Cleartext,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub id: String,
    pub session_id: Option<String>,
    pub tier: Tier,
    pub host: String,
    pub port: u16,
    pub remote_addr: Option<String>,
    pub scheme: String,
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
        tier: Tier,
        remote: Option<SocketAddr>,
        session_id: Option<String>,
    ) -> Self {
        Request {
            id: uuid::Uuid::new_v4().to_string(),
            session_id,
            tier,
            host,
            port,
            remote_addr: remote.map(|a| a.to_string()),
            scheme: if port == 443 {
                "https".into()
            } else {
                "http".into()
            },
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
