//! Per-connection handling for the Tier 1 proxy.
//!
//! Flow:
//!
//! 1. Accept a redirected TCP connection on the proxy's listen port.
//! 2. Recover the original destination via `SO_ORIGINAL_DST`.
//! 3. Peek the first bytes from the client to identify the protocol.
//!    - TLS: parse SNI from the ClientHello.
//!    - Cleartext: parse the `Host:` header (best-effort; for v1 we
//!      treat unknown-host cleartext as `<original_dst_ip>`).
//! 4. Evaluate the connection against the policy. If denied, emit
//!    `RequestDenied` and close.
//! 5. If allowed, dial the original destination and splice bytes both
//!    ways. Byte counters fold into the event emitted on connection
//!    close.

use crate::proxy::control::ControlChannel;
use crate::proxy::event::{Event, Kind, Request, Tier};
use crate::proxy::orig_dst;
use crate::proxy::policy::{Decision, Policy};
use crate::proxy::sni;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

pub async fn handle(
    mut client: TcpStream,
    policy: Arc<Policy>,
    control: Arc<ControlChannel>,
    session_id: Option<String>,
) {
    let remote = client.peer_addr().ok();
    let dst = match orig_dst::original_dst(&client) {
        Ok(addr) => addr,
        Err(err) => {
            eprintln!("condukt-egress conn: SO_ORIGINAL_DST failed: {err}");
            return;
        }
    };

    let mut peek_buf = [0u8; 1024];
    let peeked = match client.peek(&mut peek_buf).await {
        Ok(n) => n,
        Err(err) => {
            eprintln!("condukt-egress conn: peek failed: {err}");
            return;
        }
    };
    let peeked_bytes = &peek_buf[..peeked];

    let (tier, host) = identify(peeked_bytes, dst.port(), dst.ip().to_string());

    let mut request = Request::new(host.clone(), dst.port(), tier, remote, session_id);

    // Emit request_opened so the BEAM sees the connection attempt even
    // if the upstream dial later fails.
    control.emit(Event::new(Kind::RequestOpened, request.clone()));

    let decision = policy.evaluate(&host);
    if let Decision::Deny(reason) = decision {
        let event = Event::new(Kind::RequestDenied, request.clone()).with_reason(reason.as_str());
        control.emit(event);
        let _ = client.shutdown().await;
        return;
    }

    control.emit(Event::new(Kind::RequestAllowed, request.clone()));

    let upstream = match TcpStream::connect(dst).await {
        Ok(s) => s,
        Err(err) => {
            let event = Event::new(Kind::RequestClosed, request.clone())
                .with_reason(format!("upstream_dial_failed: {err}"));
            control.emit(event);
            return;
        }
    };

    let (bytes_in, bytes_out) = splice(client, upstream).await;
    request.bytes_in = bytes_in;
    request.bytes_out = bytes_out;
    request.finished_at = Some(chrono::Utc::now());

    control.emit(Event::new(Kind::RequestClosed, request));
}

fn identify(bytes: &[u8], port: u16, dst_ip: String) -> (Tier, String) {
    if sni::looks_like_tls(bytes) {
        if let Some(host) = sni::extract(bytes) {
            return (Tier::Sni, host);
        }
        return (Tier::Sni, dst_ip);
    }

    // Cleartext: try Host header.
    if let Some(host) = parse_http_host(bytes) {
        return (Tier::Cleartext, host);
    }

    let scheme_hint_tier = if port == 443 {
        Tier::Sni
    } else {
        Tier::Cleartext
    };
    (scheme_hint_tier, dst_ip)
}

fn parse_http_host(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    for line in text.lines() {
        if let Some(rest) = line
            .strip_prefix("Host:")
            .or_else(|| line.strip_prefix("host:"))
            .or_else(|| line.strip_prefix("HOST:"))
        {
            return Some(rest.trim().to_string());
        }
    }
    None
}

async fn splice(client: TcpStream, upstream: TcpStream) -> (u64, u64) {
    let (mut client_r, mut client_w) = client.into_split();
    let (mut up_r, mut up_w) = upstream.into_split();

    let client_to_up = async {
        let mut buf = [0u8; 16 * 1024];
        let mut total = 0u64;
        loop {
            match client_r.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    total += n as u64;
                    if up_w.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = up_w.shutdown().await;
        total
    };

    let up_to_client = async {
        let mut buf = [0u8; 16 * 1024];
        let mut total = 0u64;
        loop {
            match up_r.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    total += n as u64;
                    if client_w.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = client_w.shutdown().await;
        total
    };

    tokio::join!(client_to_up, up_to_client)
}
