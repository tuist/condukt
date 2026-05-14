//! `condukt-egress` is the sidecar binary that backs the Tier 1 / Tier 2
//! egress story for `Condukt.Sandbox.Kubernetes`.
//!
//! It ships as a single static binary with two operating modes selected by
//! subcommand:
//!
//! - `netfilter-setup` runs as a Kubernetes init container. It writes the
//!   iptables rules that redirect outbound TCP 80/443 traffic from the
//!   workspace container into the sidecar's transparent proxy on
//!   localhost:15001, exempting the sidecar's own uid so the proxy can
//!   reach the internet. Requires `CAP_NET_ADMIN`. Exits when done.
//!
//! - `proxy` runs as a long-lived sidecar container. It listens on
//!   localhost:15001, recovers the original destination via
//!   `SO_ORIGINAL_DST`, peeks the TLS ClientHello for SNI, evaluates the
//!   per-session policy, and either forwards bytes through transparently
//!   (Tier 1) or terminates TLS with a per-session CA-signed leaf to
//!   capture method/path/headers/body (Tier 2). Events stream back to the
//!   BEAM-side `Condukt.Sandbox.Net` over a length-prefixed JSON control
//!   channel.
//!
//! The two modes share the same image so K8s pulls one artifact for both
//! the init and sidecar containers. The pod spec selects the mode via
//! `command:`.

use clap::{Parser, Subcommand};

mod netfilter;
mod proxy;

/// Egress sidecar for Condukt's Sandbox.Net layer.
#[derive(Parser, Debug)]
#[command(name = "condukt-egress", version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    mode: Mode,
}

#[derive(Subcommand, Debug)]
enum Mode {
    /// Configure iptables NAT rules to redirect outbound TCP 80/443 to the
    /// sidecar proxy. Designed to run as a Kubernetes init container with
    /// CAP_NET_ADMIN. Exits after the rules are in place.
    NetfilterSetup(netfilter::Args),

    /// Run the transparent proxy. Long-lived sidecar mode.
    Proxy(proxy::Args),
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    let result = match cli.mode {
        Mode::NetfilterSetup(args) => netfilter::run(args),
        Mode::Proxy(args) => proxy::run(args),
    };

    match result {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("condukt-egress: {err:#}");
            std::process::ExitCode::FAILURE
        }
    }
}
