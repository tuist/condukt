//! `condukt-egress control-bridge` subcommand.
//!
//! Pumps NDJSON between stdin/stdout and the running sidecar proxy's
//! control TCP port. The BEAM-side `Condukt.Sandbox.NetworkPolicy.K8s.ControlBridge`
//! invokes this subcommand via the Kubernetes `pods/exec` API so the
//! existing exec websocket plumbing in `:k8s` carries the wire without
//! needing a port-forward implementation.
//!
//! Flow:
//!
//!   1. Connect TCP to `127.0.0.1:<control-port>` (the proxy's
//!      `--control-listen` port; default 15002).
//!   2. Spawn two tokio tasks:
//!      - stdin -> TCP (line-buffered)
//!      - TCP -> stdout (line-buffered)
//!   3. Exit when either side closes. The proxy treats peer
//!      disconnect as routine and accepts the next exec invocation.
//!
//! The line-buffered passthrough preserves the NDJSON framing the
//! proxy's control channel speaks. The bridge does not parse frame
//! contents; that's the BEAM's job.

use clap::Args as ClapArgs;
use std::error::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// Address of the proxy's control listener, reached from inside
    /// the same container.
    #[arg(
        long,
        env = "CONDUKT_EGRESS_CONTROL_BRIDGE_TARGET",
        default_value = "127.0.0.1:15002"
    )]
    pub target: String,
}

pub fn run(args: Args) -> Result<(), Box<dyn Error>> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(run_async(args))
}

async fn run_async(args: Args) -> Result<(), Box<dyn Error>> {
    let stream = TcpStream::connect(&args.target)
        .await
        .map_err(|e| format!("connecting to proxy control port {}: {}", args.target, e))?;

    let (sock_read, mut sock_write) = stream.into_split();

    // stdin -> TCP
    let to_sock = tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    let mut bytes = line.into_bytes();
                    bytes.push(b'\n');
                    if sock_write.write_all(&bytes).await.is_err() {
                        return;
                    }
                }
                Ok(None) => {
                    let _ = sock_write.shutdown().await;
                    return;
                }
                Err(_) => return,
            }
        }
    });

    // TCP -> stdout
    let from_sock = tokio::spawn(async move {
        let mut lines = BufReader::new(sock_read).lines();
        let mut stdout = tokio::io::stdout();
        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    let mut bytes = line.into_bytes();
                    bytes.push(b'\n');
                    if stdout.write_all(&bytes).await.is_err() {
                        return;
                    }
                    let _ = stdout.flush().await;
                }
                Ok(None) => return,
                Err(_) => return,
            }
        }
    });

    // Exit when either side closes.
    tokio::select! {
        _ = to_sock => {},
        _ = from_sock => {},
    }

    Ok(())
}
