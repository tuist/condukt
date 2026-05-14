//! `condukt-egress netfilter-setup` subcommand.
//!
//! Writes the iptables NAT rules that route outbound TCP 80/443 traffic
//! from the workspace container into the sidecar's transparent proxy on
//! `localhost:<proxy_port>`. Traffic originating from the sidecar itself
//! is exempted via uid match so the proxy can reach the real internet on
//! behalf of the workspace.
//!
//! Designed to run as a Kubernetes init container with `CAP_NET_ADMIN`.
//! It exits as soon as the rules are installed; iptables state persists
//! in the pod's network namespace and is inherited by the other
//! containers (sidecar + workspace) since they share that namespace.
//!
//! Rules added to the `nat` table's `OUTPUT` chain (in order):
//!
//! 1. Return loopback traffic (`-o lo`) untouched so in-pod localhost
//!    chatter is not redirected to the proxy.
//! 2. Return packets owned by the sidecar uid so the proxy's own egress
//!    is not redirected back to itself.
//! 3. Redirect remaining TCP traffic to dport 80 to `<proxy_port>`.
//! 4. Redirect remaining TCP traffic to dport 443 to `<proxy_port>`.

use clap::Args as ClapArgs;
use std::error::Error;
use std::process::Command;

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// Local port the sidecar proxy listens on.
    #[arg(long, env = "CONDUKT_EGRESS_PROXY_PORT", default_value_t = 15_001)]
    pub proxy_port: u16,

    /// UID of the sidecar process, exempted from the redirect so it can
    /// reach the real internet on behalf of the workspace.
    #[arg(long, env = "CONDUKT_EGRESS_UID", default_value_t = 1337)]
    pub sidecar_uid: u32,

    /// Path to the `iptables` binary. Defaults to looking it up on PATH.
    #[arg(long, env = "CONDUKT_EGRESS_IPTABLES_BIN", default_value = "iptables")]
    pub iptables_bin: String,
}

pub fn run(args: Args) -> Result<(), Box<dyn Error>> {
    eprintln!(
        "condukt-egress netfilter-setup: redirect tcp/80,443 -> 127.0.0.1:{}, exempt uid={}",
        args.proxy_port, args.sidecar_uid
    );

    let rules: Vec<Vec<String>> = vec![
        // 1. loopback bypass
        rule(["-A", "OUTPUT", "-o", "lo", "-j", "RETURN"]),
        // 2. sidecar uid bypass
        rule([
            "-A",
            "OUTPUT",
            "-m",
            "owner",
            "--uid-owner",
            &args.sidecar_uid.to_string(),
            "-j",
            "RETURN",
        ]),
        // 3. redirect tcp/80
        rule([
            "-A",
            "OUTPUT",
            "-p",
            "tcp",
            "--dport",
            "80",
            "-j",
            "REDIRECT",
            "--to-port",
            &args.proxy_port.to_string(),
        ]),
        // 4. redirect tcp/443
        rule([
            "-A",
            "OUTPUT",
            "-p",
            "tcp",
            "--dport",
            "443",
            "-j",
            "REDIRECT",
            "--to-port",
            &args.proxy_port.to_string(),
        ]),
    ];

    for argv in rules {
        run_iptables(&args.iptables_bin, &argv)?;
    }

    eprintln!("condukt-egress netfilter-setup: ok");
    Ok(())
}

fn rule<const N: usize>(parts: [&str; N]) -> Vec<String> {
    let mut v = Vec::with_capacity(N + 2);
    v.push("-t".into());
    v.push("nat".into());
    for p in parts {
        v.push(p.into());
    }
    v
}

fn run_iptables(bin: &str, argv: &[String]) -> Result<(), Box<dyn Error>> {
    let mut cmd = Command::new(bin);
    cmd.args(argv);

    let output = cmd.output().map_err(|e| format!("running {bin}: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "{bin} {:?} failed (exit {:?}): {}",
            argv,
            output.status.code(),
            stderr.trim()
        )
        .into());
    }

    Ok(())
}
