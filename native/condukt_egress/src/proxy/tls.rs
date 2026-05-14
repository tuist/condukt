//! Per-session CA loading + leaf certificate minting for Tier 2 TLS
//! interception.
//!
//! We accept the per-session CA (cert + key) from disk at startup,
//! parse it once, and then mint per-host leaf certs on demand as
//! connections arrive. Leaf certs are cached by SNI so repeat
//! connections to the same host don't re-pay the keygen + signing
//! cost.
//!
//! `rcgen` 0.13 exposes leaf signing as
//! `params.signed_by(&public_key, &issuer_cert, &issuer_key)`, where
//! `issuer_cert` is the issuer's `Certificate` wrapper. The wrapper is
//! used only to read the issuer's subject DN / key-identifier extension
//! when serialising the leaf — its signature and serial bytes are
//! ignored. We therefore reconstitute the CA's `Certificate` by
//! self-signing the parsed `CertificateParams` with the loaded key
//! pair. The reconstituted cert is never presented on the wire; the
//! workspace's trust store holds the original CA bytes.

use rcgen::{
    Certificate, CertificateParams, DistinguishedName, DnType, IsCa, KeyPair, KeyUsagePurpose,
    SanType,
};
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Debug, thiserror::Error)]
pub enum TlsError {
    #[error("reading CA file {0}: {1}")]
    ReadCa(String, std::io::Error),

    #[error("parsing CA cert: {0}")]
    ParseCaCert(String),

    #[error("parsing CA key: {0}")]
    ParseCaKey(String),

    #[error("rcgen: {0}")]
    Rcgen(#[from] rcgen::Error),

    #[error("rustls: {0}")]
    Rustls(#[from] rustls::Error),
}

pub struct CaContext {
    issuer_cert: Certificate,
    issuer_key: KeyPair,
    leaf_cache: Mutex<HashMap<String, Arc<ServerConfig>>>,
}

impl CaContext {
    pub async fn load(cert_path: &str, key_path: &str) -> Result<Self, TlsError> {
        let cert_pem = tokio::fs::read_to_string(cert_path)
            .await
            .map_err(|e| TlsError::ReadCa(cert_path.into(), e))?;
        let key_pem = tokio::fs::read_to_string(key_path)
            .await
            .map_err(|e| TlsError::ReadCa(key_path.into(), e))?;

        let issuer_key =
            KeyPair::from_pem(&key_pem).map_err(|e| TlsError::ParseCaKey(e.to_string()))?;

        let issuer_params = CertificateParams::from_ca_cert_pem(&cert_pem)
            .map_err(|e| TlsError::ParseCaCert(e.to_string()))?;

        // See module-level comment: the reconstituted cert is only used
        // by rcgen's signer to read the issuer's DN / extensions. Its
        // bytes are never presented on the wire.
        let issuer_cert = issuer_params.self_signed(&issuer_key)?;

        Ok(CaContext {
            issuer_cert,
            issuer_key,
            leaf_cache: Mutex::new(HashMap::new()),
        })
    }

    pub async fn server_config_for(&self, host: &str) -> Result<Arc<ServerConfig>, TlsError> {
        {
            let cache = self.leaf_cache.lock().await;
            if let Some(cfg) = cache.get(host) {
                return Ok(Arc::clone(cfg));
            }
        }

        let cfg = self.mint(host)?;
        let cfg = Arc::new(cfg);

        let mut cache = self.leaf_cache.lock().await;
        cache.insert(host.to_string(), Arc::clone(&cfg));
        Ok(cfg)
    }

    fn mint(&self, host: &str) -> Result<ServerConfig, TlsError> {
        let mut leaf_params = CertificateParams::new(vec![host.to_string()])?;
        leaf_params.distinguished_name = {
            let mut dn = DistinguishedName::new();
            dn.push(DnType::CommonName, host);
            dn
        };
        leaf_params.is_ca = IsCa::NoCa;
        leaf_params.key_usages = vec![
            KeyUsagePurpose::DigitalSignature,
            KeyUsagePurpose::KeyEncipherment,
        ];
        leaf_params.subject_alt_names = vec![SanType::DnsName(host.try_into()?)];

        let leaf_key = KeyPair::generate()?;
        let leaf_cert = leaf_params.signed_by(&leaf_key, &self.issuer_cert, &self.issuer_key)?;

        let leaf_der: CertificateDer<'static> = leaf_cert.der().clone();
        let leaf_key_der = leaf_key.serialize_der();

        let cert_chain: Vec<CertificateDer<'static>> = vec![leaf_der];
        let private_key: PrivateKeyDer<'static> =
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key_der));

        let mut cfg = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(cert_chain, private_key)?;

        // ALPN: signal we speak HTTP/1.1. h2 termination is not yet
        // implemented; clients that require h2 fall through to passthrough
        // (Tier 1) at the connection level when their handshake fails.
        cfg.alpn_protocols = vec![b"http/1.1".to_vec()];

        Ok(cfg)
    }
}
