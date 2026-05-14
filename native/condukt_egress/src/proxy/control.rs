//! Control channel client. Streams NDJSON events to the BEAM-side
//! `Condukt.Sandbox.Net` decoder over a long-lived TCP connection.
//!
//! In K8s the BEAM reaches this connection via the Kubernetes
//! port-forward API: `Condukt.Sandbox.Kubernetes` opens a port-forward
//! to the sidecar's `--control-port`, then dials the forwarded local
//! port. The sidecar accepts a single inbound connection on startup; if
//! it disconnects, events are buffered up to `BUFFER_CAP` then dropped
//! (with a count surfaced in a periodic warning).

use crate::proxy::event::Event;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, mpsc};

const BUFFER_CAP: usize = 1024;

pub struct ControlChannel {
    sender: mpsc::Sender<Event>,
}

impl ControlChannel {
    /// Spawn a control channel that listens on `bind` (typically
    /// `0.0.0.0:15002`) and accepts a single inbound connection from the
    /// BEAM-side port-forward. Events submitted via `emit` are streamed
    /// to the connected peer as NDJSON.
    pub async fn start(bind: &str) -> std::io::Result<Self> {
        let listener = TcpListener::bind(bind).await?;
        let (tx, rx) = mpsc::channel::<Event>(BUFFER_CAP);
        let rx = Arc::new(Mutex::new(rx));

        tokio::spawn(accept_loop(listener, rx));

        Ok(ControlChannel { sender: tx })
    }

    /// Submit an event for delivery. Non-blocking; if the BEAM peer is
    /// disconnected and the buffer is full, the event is dropped. This
    /// keeps the data plane decoupled from the control plane.
    pub fn emit(&self, event: Event) {
        if let Err(err) = self.sender.try_send(event) {
            // Buffer full or channel closed. Log once per drop.
            eprintln!("condukt-egress control: dropped event ({err})");
        }
    }
}

async fn accept_loop(listener: TcpListener, rx: Arc<Mutex<mpsc::Receiver<Event>>>) {
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(pair) => pair,
            Err(err) => {
                eprintln!("condukt-egress control: accept failed: {err}");
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }
        };

        eprintln!("condukt-egress control: peer connected from {peer}");
        let mut rx = rx.lock().await;
        write_loop(stream, &mut rx).await;
        eprintln!("condukt-egress control: peer disconnected");
    }
}

async fn write_loop(mut stream: TcpStream, rx: &mut mpsc::Receiver<Event>) {
    while let Some(event) = rx.recv().await {
        let mut line = match serde_json::to_string(&event) {
            Ok(json) => json,
            Err(err) => {
                eprintln!("condukt-egress control: serialize failed: {err}");
                continue;
            }
        };
        line.push('\n');

        if let Err(err) = stream.write_all(line.as_bytes()).await {
            eprintln!("condukt-egress control: write failed: {err}");
            return;
        }
    }
}
