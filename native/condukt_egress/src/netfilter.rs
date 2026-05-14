//! `condukt-egress netfilter-setup` subcommand.
//!
//! Implementation lands in P3.

use clap::Args as ClapArgs;
use std::error::Error;

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// Local port the sidecar proxy listens on.
    #[arg(long, env = "CONDUKT_EGRESS_PROXY_PORT", default_value_t = 15_001)]
    pub proxy_port: u16,

    /// UID of the sidecar process, exempted from the redirect so it can
    /// reach the real internet on behalf of the workspace.
    #[arg(long, env = "CONDUKT_EGRESS_UID", default_value_t = 1337)]
    pub sidecar_uid: u32,
}

pub fn run(_args: Args) -> Result<(), Box<dyn Error>> {
    Err("netfilter-setup not yet implemented (lands in P3)".into())
}
