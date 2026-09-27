//! Shared early-disconnect matrix with verified local TLS and synthetic secrets.
#![expect(
    clippy::unwrap_used,
    reason = "controlled fixtures and test assertions"
)]

use std::sync::Arc;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, mpsc, oneshot};
use tokio::time::{Duration, timeout};
use tokio_rustls::TlsAcceptor;

use crate::config::ProxyConfig;
use crate::proxy::forward_tests::{generate_fixtures, trusted_connector};
use crate::proxy::{Ctx, TestDestination, accept_loop};

#[derive(Clone, Copy)]
enum Phase {
    BeforeHeaders,
    DuringBody,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::BeforeHeaders => "beforeHeaders",
            Self::DuringBody => "duringBody",
        }
    }
}

#[derive(Clone, Copy)]
enum Closure {
    AbruptTcp,
    CleanTls,
}

impl Closure {
    fn name(self) -> &'static str {
        match self {
            Self::AbruptTcp => "abruptTCP",
            Self::CleanTls => "cleanTLS",
        }
    }
}

#[tokio::test]
async fn upstream_disconnect_closes_guest_and_restores_permits() {
    let fixtures = generate_fixtures();
    let mut observations = Vec::new();
    for provider in ["anthropic", "openai"] {
        for phase in [Phase::BeforeHeaders, Phase::DuringBody] {
            for closure in [Closure::AbruptTcp, Closure::CleanTls] {
                observations.extend(
                    timeout(
                        Duration::from_secs(10),
                        disconnect_case(fixtures.path(), provider, phase, closure),
                    )
                    .await
                    .unwrap(),
                );
            }
        }
    }
    if let Some(path) = std::env::var_os("COOP_DISCONNECT_OBSERVATIONS") {
        std::fs::write(path, serde_json::to_vec_pretty(&observations).unwrap()).unwrap();
    }
}

struct DisconnectPeer {
    address: std::net::SocketAddr,
    admitted: mpsc::Receiver<()>,
    close: mpsc::Sender<()>,
    task: tokio::task::JoinHandle<()>,
}

async fn disconnect_peer(
    fixtures: &std::path::Path,
    phase: Phase,
    closure: Closure,
) -> DisconnectPeer {
    let acceptor = TlsAcceptor::from(Arc::new(
        rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![CertificateDer::from(
                    std::fs::read(fixtures.join("forward_leaf.der")).unwrap(),
                )],
                PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
                    std::fs::read(fixtures.join("forward_leaf.pkcs8.der")).unwrap(),
                )),
            )
            .unwrap(),
    ));
    let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream_address = upstream.local_addr().unwrap();
    let (admitted_tx, admitted) = mpsc::channel(1);
    let (close_tx, mut close_rx) = mpsc::channel(1);
    let task = tokio::spawn(async move {
        for _ in 0..2 {
            let mut tls = acceptor
                .accept(upstream.accept().await.unwrap().0)
                .await
                .unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(tls.read_u8().await.unwrap());
                assert!(request.len() < 4096);
            }
            let request = String::from_utf8(request).unwrap().to_ascii_lowercase();
            assert!(request.contains("content-length: 0\r\n"));
            assert!(request.contains("upstream-disconnect-test-only"));
            admitted_tx.send(()).await.unwrap();
            if matches!(phase, Phase::DuringBody) {
                tls.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\npart")
                    .await
                    .unwrap();
                tls.flush().await.unwrap();
            }
            // The guest confirms receipt of the partial body before closure.
            close_rx.recv().await.unwrap();
            if matches!(closure, Closure::CleanTls) {
                tls.shutdown().await.unwrap();
            }
            drop(tls);
        }
    });
    DisconnectPeer {
        address: upstream_address,
        admitted,
        close: close_tx,
        task,
    }
}

async fn disconnect_case(
    fixtures: &std::path::Path,
    provider: &'static str,
    phase: Phase,
    closure: Closure,
) -> Vec<serde_json::Value> {
    let DisconnectPeer {
        address: upstream_address,
        mut admitted,
        close: close_tx,
        task: peer,
    } = disconnect_peer(fixtures, phase, closure).await;
    let token = "a".repeat(64);
    let config = serde_json::json!({
        "version": 1, "listen": "127.0.0.1:0", "provider": provider,
        "capability_token": token,
        "injection": {"scheme": if provider == "anthropic" { "x_api_key" } else { "bearer" },
            "credential": "upstream-disconnect-test-only"}
    });
    let mut ctx = Ctx::new(ProxyConfig::from_json(&config.to_string()).unwrap()).unwrap();
    ctx.connector = trusted_connector(fixtures);
    ctx.upstream_destination = Some(TestDestination::Socket(upstream_address));
    ctx.permits = Arc::new(Semaphore::new(1));
    ctx.connections = Arc::new(Semaphore::new(1));
    let requests = Arc::clone(&ctx.permits);
    let connections = Arc::clone(&ctx.connections);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (stop, stopped) = oneshot::channel();
    let proxy = tokio::spawn(accept_loop(ctx, listener, async {
        let _ = stopped.await;
    }));
    let path = if provider == "anthropic" {
        "/v1/messages"
    } else {
        "/v1/responses"
    };
    let mut observations = Vec::new();
    for round in 0..2 {
        let mut guest = TcpStream::connect(address).await.unwrap();
        guest.write_all(format!(
            "POST {path} HTTP/1.1\r\nHost: ignored\r\nAuthorization: Bearer {token}\r\nContent-Length: 0\r\n\r\n"
        ).as_bytes()).await.unwrap();
        admitted.recv().await.unwrap();
        let mut wire = Vec::new();
        if matches!(phase, Phase::DuringBody) {
            while !wire.ends_with(b"\r\n\r\npart") {
                wire.push(guest.read_u8().await.unwrap());
                assert!(wire.len() < 4096);
            }
        }
        close_tx.send(()).await.unwrap();
        // Keep the guest write side open: only peer EOF can complete this read.
        timeout(Duration::from_secs(2), guest.read_to_end(&mut wire))
            .await
            .unwrap()
            .unwrap();
        let wire = String::from_utf8(wire).unwrap();
        assert_eq!(wire.matches("HTTP/1.1").count(), 1);
        let (headers, body) = wire.split_once("\r\n\r\n").unwrap();
        let status: u16 = headers.split_whitespace().nth(1).unwrap().parse().unwrap();
        match phase {
            Phase::BeforeHeaders => {
                assert_eq!(status, 502);
                assert_eq!(body, "upstream request failed");
            }
            Phase::DuringBody => {
                assert_eq!(status, 200);
                assert!(
                    format!("{}\r\n", headers.to_ascii_lowercase())
                        .contains("content-length: 8\r\n")
                );
                assert_eq!(body, "part");
            }
        }
        assert!(!wire.contains(&token));
        assert!(!wire.contains("upstream-disconnect-test-only"));
        timeout(Duration::from_secs(2), async {
            while connections.available_permits() != 1 || requests.available_permits() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        observations.push(serde_json::json!({
            "id": format!("{provider}-{}-{}-{round}", phase.name(), closure.name()),
            "response_status": status, "response_body": body, "connection_closed": true,
            "connection_slots": connections.available_permits(),
            "request_slots": requests.available_permits(),
        }));
    }
    stop.send(()).unwrap();
    peer.await.unwrap();
    proxy.await.unwrap();
    observations
}
