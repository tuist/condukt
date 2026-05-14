//! Per-connection handling.
//!
//! Two paths:
//!
//! - Tier 1 (no CA configured, or non-TLS traffic): peek bytes, get
//!   SNI / Host header, evaluate policy, then transparently splice
//!   bytes between client and upstream. The proxy never sees plaintext
//!   bodies on TLS in this mode.
//! - Tier 2 (CA configured AND traffic is TLS AND the client trusts
//!   the CA): terminate TLS with a per-SNI leaf cert signed by our CA,
//!   parse the HTTP/1.1 request line + headers on the cleartext side,
//!   then forward the request to a fresh TLS connection to the real
//!   destination. Method, path, and headers land in the
//!   `request_closed` event. If the TLS handshake fails (client does
//!   not trust the CA), the connection cannot be salvaged at that
//!   point — the bytes have already been consumed by the rustls
//!   accept attempt. Future enhancement: probe via a side channel
//!   before consuming.

use crate::proxy::control::ControlChannel;
use crate::proxy::event::{Event, Kind, Request, Tier};
use crate::proxy::http1;
use crate::proxy::orig_dst;
use crate::proxy::policy::{Decision, Policy};
use crate::proxy::sni;
use crate::proxy::tls::CaContext;
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, RootCertStore};
use std::sync::{Arc, OnceLock};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::{TlsAcceptor, TlsConnector};

pub async fn handle(
    mut client: TcpStream,
    policy: Arc<Policy>,
    control: Arc<ControlChannel>,
    ca: Option<Arc<CaContext>>,
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

    let (initial_tier, host) = identify(peeked_bytes, dst.port(), dst.ip().to_string());

    let mut request = Request::new(
        host.clone(),
        dst.port(),
        initial_tier.clone(),
        remote,
        session_id,
    );
    control.emit(Event::new(Kind::RequestOpened, request.clone()));

    let decision = policy.evaluate(&host);
    if let Decision::Deny(reason) = decision {
        let event = Event::new(Kind::RequestDenied, request.clone()).with_reason(reason.as_str());
        control.emit(event);
        let _ = client.shutdown().await;
        return;
    }
    control.emit(Event::new(Kind::RequestAllowed, request.clone()));

    let is_tls = matches!(initial_tier, Tier::Sni);
    let should_mitm = is_tls && ca.is_some() && dst.port() == 443;

    if should_mitm {
        let ca = ca.as_ref().expect("ca presence checked").clone();
        match mitm(client, &host, dst, ca, &mut request).await {
            Ok(()) => {
                control.emit(Event::new(Kind::RequestClosed, request));
                return;
            }
            Err(MitmError::HandshakeFailed) => {
                let event =
                    Event::new(Kind::RequestClosed, request).with_reason("tls_handshake_failed");
                control.emit(event);
                return;
            }
            Err(MitmError::Other(msg)) => {
                let event = Event::new(Kind::RequestClosed, request)
                    .with_reason(format!("mitm_error: {msg}"));
                control.emit(event);
                return;
            }
        }
    }

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

enum MitmError {
    HandshakeFailed,
    Other(String),
}

async fn mitm(
    client: TcpStream,
    host: &str,
    dst: std::net::SocketAddr,
    ca: Arc<CaContext>,
    request: &mut Request,
) -> Result<(), MitmError> {
    let server_cfg = ca
        .server_config_for(host)
        .await
        .map_err(|e| MitmError::Other(format!("server_config: {e}")))?;
    let acceptor = TlsAcceptor::from(server_cfg);

    let tls_client = acceptor
        .accept(client)
        .await
        .map_err(|_| MitmError::HandshakeFailed)?;

    // Upstream TLS client. We use the system default roots; in v1 the
    // sidecar image bakes in webpki-roots-equivalent (gcr.io/distroless
    // ships with /etc/ssl/certs).
    let connector =
        build_tls_connector().map_err(|e| MitmError::Other(format!("tls_connector: {e}")))?;
    let server_name = ServerName::try_from(host.to_string())
        .map_err(|e| MitmError::Other(format!("sni: {e}")))?;

    let upstream_tcp = TcpStream::connect(dst)
        .await
        .map_err(|e| MitmError::Other(format!("upstream_connect: {e}")))?;

    let tls_upstream = connector
        .connect(server_name, upstream_tcp)
        .await
        .map_err(|e| MitmError::Other(format!("upstream_tls: {e}")))?;

    // Read HTTP request head, capture method/path/headers, then splice
    // the rest of the bytes.
    let (mut cr, mut cw) = tokio::io::split(tls_client);
    let (mut ur, mut uw) = tokio::io::split(tls_upstream);

    let mut head_buf = Vec::with_capacity(8 * 1024);
    let mut tmp = [0u8; 4096];

    let head = loop {
        let n = cr
            .read(&mut tmp)
            .await
            .map_err(|e| MitmError::Other(format!("read_head: {e}")))?;
        if n == 0 {
            break None;
        }
        head_buf.extend_from_slice(&tmp[..n]);

        match http1::parse(&head_buf) {
            Ok(Some(head)) => break Some(head),
            Ok(None) => continue,
            Err(_) => break None,
        }
    };

    if let Some(head) = head {
        request.tier = Tier::Body;
        request.method = Some(head.method.clone());
        request.path = Some(head.path.clone());
        request.request_headers = Some(head.headers);
        let _ = head.head_len;
    }

    // Forward the buffer we already read.
    uw.write_all(&head_buf)
        .await
        .map_err(|e| MitmError::Other(format!("forward_head: {e}")))?;

    // From here, splice both directions.
    let client_to_up = async {
        let mut buf = [0u8; 16 * 1024];
        let mut total = 0u64;
        loop {
            match cr.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    total += n as u64;
                    if uw.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = uw.shutdown().await;
        total
    };

    let up_to_client = async {
        let mut buf = [0u8; 16 * 1024];
        let mut total = 0u64;
        loop {
            match ur.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    total += n as u64;
                    if cw.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = cw.shutdown().await;
        total
    };

    let (out, inb) = tokio::join!(client_to_up, up_to_client);
    request.bytes_out = head_buf.len() as u64 + out;
    request.bytes_in = inb;
    request.finished_at = Some(chrono::Utc::now());
    Ok(())
}

fn build_tls_connector() -> Result<TlsConnector, String> {
    static CONFIG: OnceLock<Arc<ClientConfig>> = OnceLock::new();

    let cfg = CONFIG
        .get_or_init(|| {
            let mut roots = RootCertStore::empty();
            for cert in load_system_roots() {
                let _ = roots.add(cert);
            }
            Arc::new(
                ClientConfig::builder()
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            )
        })
        .clone();
    Ok(TlsConnector::from(cfg))
}

fn load_system_roots() -> Vec<rustls::pki_types::CertificateDer<'static>> {
    // Read /etc/ssl/certs/ca-certificates.crt (the Debian / distroless
    // bundle our image is built on). On other platforms we'd want
    // rustls-native-certs; v1 only runs in distroless so the well-known
    // path is sufficient.
    let path = "/etc/ssl/certs/ca-certificates.crt";
    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    let mut cursor = std::io::Cursor::new(bytes);
    let mut out = Vec::new();
    while let Ok(Some(item)) = rustls_pemfile::read_one(&mut cursor) {
        if let rustls_pemfile::Item::X509Certificate(der) = item {
            out.push(der);
        }
    }
    out
}

fn identify(bytes: &[u8], port: u16, dst_ip: String) -> (Tier, String) {
    if sni::looks_like_tls(bytes) {
        if let Some(host) = sni::extract(bytes) {
            return (Tier::Sni, host);
        }
        return (Tier::Sni, dst_ip);
    }

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
