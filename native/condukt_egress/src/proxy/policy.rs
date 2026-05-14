//! Sidecar-side mirror of `Condukt.Sandbox.Net.Policy`.
//!
//! The BEAM authors the policy and bakes it into the pod as a JSON file
//! at `/etc/condukt/policy.json` (or any path provided via
//! `--policy-file`). The sidecar reads it once at startup, holds it in
//! memory for the lifetime of the session, and evaluates every connection
//! against it.
//!
//! There is no live-reload path in v1 — policy is immutable once the pod
//! starts. If an operator needs to change policy, they end the session
//! and start a fresh one. This matches the per-session CA lifecycle.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct Policy {
    #[serde(default)]
    pub allow_hosts: Vec<String>,

    #[serde(default)]
    pub deny_hosts: Vec<String>,

    #[serde(default = "default_deny")]
    pub default: Action,

    #[serde(default)]
    pub redact: Vec<String>,

    #[serde(default = "default_max_body_capture")]
    pub max_body_capture: usize,

    /// When true, hosts that don't match the static allow/deny lists
    /// trigger a `decision_request` over the control channel rather
    /// than applying `default`. The BEAM's decider answers with a
    /// `decision` frame. On timeout / channel unavailable, the
    /// sidecar applies `default` as the fallback.
    #[serde(default)]
    pub use_decider: bool,

    /// Maximum time (milliseconds) the sidecar waits for a
    /// `decision` reply from the BEAM. Mirrors
    /// `Condukt.Sandbox.Net.Policy.decide_timeout`.
    #[serde(default = "default_decide_timeout_ms")]
    pub decide_timeout_ms: u64,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Allow,
    #[default]
    Deny,
}

fn default_deny() -> Action {
    Action::Deny
}

fn default_max_body_capture() -> usize {
    4096
}

fn default_decide_timeout_ms() -> u64 {
    5_000
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Decide,
    Deny(DenyReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DenyReason {
    MatchedDenyList,
    NoAllowMatch,
    DefaultDeny,
}

impl DenyReason {
    pub fn as_str(self) -> &'static str {
        match self {
            DenyReason::MatchedDenyList => "matched_deny_list",
            DenyReason::NoAllowMatch => "no_allow_match",
            DenyReason::DefaultDeny => "default_deny",
        }
    }
}

impl Policy {
    /// Evaluate a hostname against the policy. Mirrors the BEAM-side
    /// `Condukt.Sandbox.Net.Policy.evaluate/2`.
    pub fn evaluate(&self, host: &str) -> Decision {
        let host_lc = host.to_ascii_lowercase();

        if matches_any(&host_lc, &self.deny_hosts) {
            return Decision::Deny(DenyReason::MatchedDenyList);
        }

        if matches_any(&host_lc, &self.allow_hosts) {
            return Decision::Allow;
        }

        if self.use_decider {
            return Decision::Decide;
        }

        if self.allow_hosts.is_empty() {
            return match self.default {
                Action::Allow => Decision::Allow,
                Action::Deny => Decision::Deny(DenyReason::DefaultDeny),
            };
        }

        match self.default {
            Action::Allow => Decision::Allow,
            Action::Deny => Decision::Deny(DenyReason::NoAllowMatch),
        }
    }
}

fn matches_any(host: &str, patterns: &[String]) -> bool {
    patterns.iter().any(|p| matches_one(host, p))
}

/// Host-glob match. `*` matches a single DNS label, `**` matches one or
/// more dot-separated labels. Case-insensitive.
fn matches_one(host: &str, pattern: &str) -> bool {
    let pattern = pattern.to_ascii_lowercase();
    let regex = compile(&pattern);
    regex_match(&regex, host)
}

/// Compile a host glob to a sequence of regex-equivalent tokens. We use
/// a minimal hand-rolled matcher rather than pulling in the `regex` crate
/// for one job.
fn compile(pattern: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = pattern.chars().collect();
    let mut i = 0;
    let mut literal = String::new();

    while i < chars.len() {
        if chars[i] == '*' {
            if !literal.is_empty() {
                tokens.push(Token::Literal(literal.clone()));
                literal.clear();
            }
            if i + 1 < chars.len() && chars[i + 1] == '*' {
                tokens.push(Token::DoubleStar);
                i += 2;
            } else {
                tokens.push(Token::Star);
                i += 1;
            }
        } else {
            literal.push(chars[i]);
            i += 1;
        }
    }
    if !literal.is_empty() {
        tokens.push(Token::Literal(literal));
    }

    tokens
}

#[derive(Debug, Clone)]
enum Token {
    Literal(String),
    Star,       // [^.]+
    DoubleStar, // .+
}

fn regex_match(tokens: &[Token], host: &str) -> bool {
    match_tokens(tokens, host)
}

fn match_tokens(tokens: &[Token], input: &str) -> bool {
    match tokens.split_first() {
        None => input.is_empty(),
        Some((Token::Literal(lit), rest)) => {
            if let Some(remaining) = input.strip_prefix(lit.as_str()) {
                match_tokens(rest, remaining)
            } else {
                false
            }
        }
        Some((Token::Star, rest)) => {
            // [^.]+ — must consume at least one non-dot character, greedy.
            for (idx, ch) in input.char_indices() {
                if ch == '.' {
                    if idx == 0 {
                        return false;
                    }
                    return match_tokens(rest, &input[idx..]);
                }
            }
            // Whole rest is non-dot: consume all if there's anything.
            if input.is_empty() {
                false
            } else {
                match_tokens(rest, "")
            }
        }
        Some((Token::DoubleStar, rest)) => {
            // .+ — at least one character, any. Try every split.
            if input.is_empty() {
                return false;
            }
            for (idx, _) in input.char_indices().skip(1) {
                if match_tokens(rest, &input[idx..]) {
                    return true;
                }
            }
            match_tokens(rest, "")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_match() {
        let p = Policy {
            allow_hosts: vec!["api.github.com".into()],
            ..Default::default()
        };
        assert_eq!(p.evaluate("api.github.com"), Decision::Allow);
        assert!(matches!(p.evaluate("github.com"), Decision::Deny(_)));
    }

    #[test]
    fn single_star_one_label() {
        let p = Policy {
            allow_hosts: vec!["*.openai.com".into()],
            ..Default::default()
        };
        assert_eq!(p.evaluate("api.openai.com"), Decision::Allow);
        assert!(matches!(p.evaluate("v1.api.openai.com"), Decision::Deny(_)));
        assert!(matches!(p.evaluate("openai.com"), Decision::Deny(_)));
    }

    #[test]
    fn double_star_multi_label() {
        let p = Policy {
            allow_hosts: vec!["**.googleapis.com".into()],
            ..Default::default()
        };
        assert_eq!(p.evaluate("v1.api.googleapis.com"), Decision::Allow);
        assert_eq!(p.evaluate("api.googleapis.com"), Decision::Allow);
        assert!(matches!(p.evaluate("googleapis.com"), Decision::Deny(_)));
    }

    #[test]
    fn deny_overrides_allow() {
        let p = Policy {
            allow_hosts: vec!["*.example.com".into()],
            deny_hosts: vec!["secret.example.com".into()],
            ..Default::default()
        };
        assert_eq!(
            p.evaluate("secret.example.com"),
            Decision::Deny(DenyReason::MatchedDenyList)
        );
        assert_eq!(p.evaluate("public.example.com"), Decision::Allow);
    }

    #[test]
    fn empty_allow_with_default_allow_permits() {
        let p = Policy {
            allow_hosts: vec![],
            default: Action::Allow,
            ..Default::default()
        };
        assert_eq!(p.evaluate("anything.com"), Decision::Allow);
    }

    #[test]
    fn empty_allow_with_default_deny_blocks() {
        let p = Policy {
            allow_hosts: vec![],
            default: Action::Deny,
            ..Default::default()
        };
        assert!(matches!(
            p.evaluate("anything.com"),
            Decision::Deny(DenyReason::DefaultDeny)
        ));
    }

    #[test]
    fn case_insensitive() {
        let p = Policy {
            allow_hosts: vec!["API.github.com".into()],
            ..Default::default()
        };
        assert_eq!(p.evaluate("api.github.com"), Decision::Allow);
        assert_eq!(p.evaluate("API.GITHUB.COM"), Decision::Allow);
    }

    #[test]
    fn parses_json() {
        let json = r#"{"allow_hosts":["api.github.com"],"default":"deny"}"#;
        let p: Policy = serde_json::from_str(json).unwrap();
        assert_eq!(p.allow_hosts, vec!["api.github.com"]);
        assert_eq!(p.default, Action::Deny);
    }
}
