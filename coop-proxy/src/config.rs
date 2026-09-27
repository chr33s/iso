//! Startup configuration for `coop-proxy`, read once from stdin.
//!
//! `coop` resolves the real upstream credential on the host (via its `cmd:`
//! secret-resolution machinery) and hands the whole blob to the proxy over a
//! stdin pipe — never argv (world-readable through `/proc/<pid>/cmdline`) and
//! never a file on disk. The proxy deserializes it once at startup, closes
//! stdin, and holds the secret in process memory only.

use std::fmt;
use std::net::SocketAddr;

use serde::Deserialize;

/// A secret string that never appears in `Debug` output or logs.
#[derive(Clone, Deserialize)]
#[serde(transparent)]
pub struct Secret(String);

impl Secret {
    /// Borrow the underlying value. Named to flag every read at review time.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

/// How the proxy injects the real upstream credential onto forwarded
/// requests. The guest's credential slot is always stripped first (see
/// [`crate::proxy`]); this decides the header that replaces it.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "scheme", rename_all = "snake_case", deny_unknown_fields)]
pub enum Injection {
    /// Anthropic API key → `x-api-key: <credential>`.
    XApiKey { credential: Secret },
    /// Bearer token (e.g. a Claude `setup-token`) →
    /// `authorization: Bearer <credential>`.
    Bearer { credential: Secret },
}

/// Compiled provider policy; startup cannot introduce arbitrary destinations.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Anthropic,
    Openai,
}

impl Provider {
    pub fn host(self) -> &'static str {
        match self {
            Self::Anthropic => "api.anthropic.com",
            Self::Openai => "api.openai.com",
        }
    }
}

/// Validated startup state. Deserialization is private so callers cannot skip
/// version, listener, capability, and credential checks.
#[derive(Debug, Clone)]
pub struct ProxyConfig {
    pub listen: SocketAddr,
    pub capability_token: Secret,
    pub provider: Provider,
    pub injection: Injection,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireConfig {
    version: u32,
    listen: SocketAddr,
    capability_token: Secret,
    provider: Provider,
    injection: Injection,
}

impl ProxyConfig {
    pub fn from_json(s: &str) -> anyhow::Result<Self> {
        // Decoder errors can quote input values (including secrets). Never
        // attach the underlying error to a startup diagnostic.
        let wire: WireConfig =
            serde_json::from_str(s).map_err(|_| anyhow::anyhow!("invalid proxy startup schema"))?;
        anyhow::ensure!(wire.version == 1, "unsupported proxy startup version");
        anyhow::ensure!(
            wire.listen.ip().is_loopback(),
            "proxy listener must be loopback"
        );
        let token = wire.capability_token.expose().as_bytes();
        anyhow::ensure!(
            token.len() == 64
                && token
                    .iter()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b)),
            "capability must be 64 lowercase hexadecimal characters"
        );
        anyhow::ensure!(
            !(wire.provider == Provider::Openai
                && matches!(wire.injection, Injection::XApiKey { .. })),
            "incompatible provider credential scheme"
        );
        let credential = match &wire.injection {
            Injection::XApiKey { credential } | Injection::Bearer { credential } => {
                credential.expose()
            }
        };
        anyhow::ensure!(
            !credential.is_empty() && credential.bytes().all(|b| (0x21..=0x7e).contains(&b)),
            "invalid provider credential"
        );
        Ok(Self {
            listen: wire.listen,
            capability_token: wire.capability_token,
            provider: wire.provider,
            injection: wire.injection,
        })
    }
}

#[cfg(test)]
#[expect(clippy::unwrap_used, reason = "tests")]
mod tests {
    use crate::config::{Provider, ProxyConfig};
    use serde_json::{Value, json};

    fn sample() -> Value {
        json!({ "version": 1, "listen": "127.0.0.1:8788",
            "provider": "anthropic", "capability_token": "a".repeat(64),
            "injection": { "scheme": "x_api_key", "credential": "sk-secret" } })
    }

    #[test]
    fn valid_provider_scheme_combinations() {
        for (provider, scheme, host) in [
            ("anthropic", "x_api_key", "api.anthropic.com"),
            ("anthropic", "bearer", "api.anthropic.com"),
            ("openai", "bearer", "api.openai.com"),
        ] {
            let mut value = sample();
            value["provider"] = json!(provider);
            value["injection"]["scheme"] = json!(scheme);
            let cfg = ProxyConfig::from_json(&value.to_string()).unwrap();
            assert_eq!(cfg.provider.host(), host);
            assert_eq!(cfg.listen.port(), 8788);
            assert_eq!(cfg.capability_token.expose(), "a".repeat(64));
        }
        assert_eq!(Provider::Openai.host(), "api.openai.com");
    }

    #[test]
    fn rejects_invalid_startup_fields() {
        for (field, bad) in [
            ("version", json!(0)),
            ("version", json!(2)),
            ("provider", json!("evil.example")),
            ("upstream_host", json!("api.anthropic.com")),
            ("extra", json!(true)),
        ] {
            let mut value = sample();
            value[field] = bad;
            assert!(
                ProxyConfig::from_json(&value.to_string()).is_err(),
                "{field}"
            );
        }
        for field in [
            "version",
            "listen",
            "provider",
            "capability_token",
            "injection",
        ] {
            let mut value = sample();
            value.as_object_mut().unwrap().remove(field);
            assert!(
                ProxyConfig::from_json(&value.to_string()).is_err(),
                "{field}"
            );
        }
        for listen in ["0.0.0.0:1", "[::]:1", "172.16.0.1:1", "[2001:db8::1]:1"] {
            let mut value = sample();
            value["listen"] = json!(listen);
            assert!(ProxyConfig::from_json(&value.to_string()).is_err());
        }
        for listen in ["127.0.0.1:1", "[::1]:1"] {
            let mut value = sample();
            value["listen"] = json!(listen);
            assert!(ProxyConfig::from_json(&value.to_string()).is_ok());
        }
        for token in [
            String::new(),
            "a".repeat(63),
            "a".repeat(65),
            "A".repeat(64),
            "g".repeat(64),
        ] {
            let mut value = sample();
            value["capability_token"] = json!(token);
            assert!(ProxyConfig::from_json(&value.to_string()).is_err());
        }
    }

    #[test]
    fn rejects_invalid_injection_without_echoing_secrets() {
        for injection in [
            json!({"scheme": "basic", "credential": "sk-secret"}),
            json!({"scheme": "bearer", "credential": ""}),
            json!({"scheme": "bearer", "credential": "sk-secret\r\n"}),
            json!({"scheme": "bearer", "credential": "sk-secret", "extra": true}),
        ] {
            let mut value = sample();
            value["injection"] = injection;
            let err = ProxyConfig::from_json(&value.to_string()).unwrap_err();
            assert!(!format!("{err:#}").contains("sk-secret"));
        }
        let mut value = sample();
        value["provider"] = json!("openai");
        assert!(ProxyConfig::from_json(&value.to_string()).is_err());
        let rendered = format!(
            "{:?}",
            ProxyConfig::from_json(&sample().to_string()).unwrap()
        );
        assert!(!rendered.contains("sk-secret"));
        assert!(!rendered.contains(&"a".repeat(64)));
    }
}
