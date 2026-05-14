//! `condukt-egress proxy` subcommand.
//!
//! Tier 1 implementation lands in P4; Tier 2 (MITM with per-session CA)
//! lands in P6.

use clap::Args as ClapArgs;
use std::error::Error;

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// Address to listen on for redirected traffic from the workspace.
    #[arg(long, env = "CONDUKT_EGRESS_LISTEN", default_value = "0.0.0.0:15001")]
    pub listen: String,

    /// Address of the BEAM-side control channel that ingests events.
    /// Set by the Kubernetes sandbox when the pod is created.
    #[arg(long, env = "CONDUKT_EGRESS_CONTROL_ADDR")]
    pub control_addr: Option<String>,

    /// Optional path to the per-session CA certificate, in PEM. When set,
    /// the proxy attempts Tier 2 TLS termination using this CA.
    #[arg(long, env = "CONDUKT_EGRESS_CA_CERT")]
    pub ca_cert_path: Option<String>,

    /// Optional path to the per-session CA private key, in PEM.
    #[arg(long, env = "CONDUKT_EGRESS_CA_KEY")]
    pub ca_key_path: Option<String>,

    /// Session id passed through on every emitted event.
    #[arg(long, env = "CONDUKT_EGRESS_SESSION_ID")]
    pub session_id: Option<String>,
}

pub fn run(_args: Args) -> Result<(), Box<dyn Error>> {
    Err("proxy not yet implemented (lands in P4)".into())
}
