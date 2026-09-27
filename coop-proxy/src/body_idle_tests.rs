//! A partially forwarded upload must time out relative to its last body byte.
#![expect(
    clippy::unwrap_used,
    reason = "controlled fixtures and test assertions"
)]

use std::convert::Infallible;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use http_body_util::{BodyExt, Empty};
use hyper::body::{Bytes, Incoming};
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Duration, timeout};
use tokio_rustls::TlsAcceptor;

use crate::config::ProxyConfig;
use crate::proxy::forward_tests::{generate_fixtures, trusted_connector};
use crate::proxy::{Ctx, TestDestination, accept_loop};

struct UploadPeer {
    address: std::net::SocketAddr,
    bytes: mpsc::Receiver<Bytes>,
    ended: Arc<AtomicBool>,
    task: tokio::task::JoinHandle<()>,
}

async fn upload_peer(fixtures: &std::path::Path, provider: &'static str) -> UploadPeer {
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
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (bytes_tx, bytes) = mpsc::channel(4);
    let ended = Arc::new(AtomicBool::new(false));
    let upload_ended = Arc::clone(&ended);
    let task = tokio::spawn(async move {
        let tls = acceptor
            .accept(listener.accept().await.unwrap().0)
            .await
            .unwrap();
        let _ = hyper::server::conn::http1::Builder::new()
            .serve_connection(
                TokioIo::new(tls),
                service_fn(move |request: Request<Incoming>| {
                    let bytes = bytes_tx.clone();
                    let ended = Arc::clone(&upload_ended);
                    async move {
                        assert_eq!(request.headers()["host"], format!("api.{provider}.com"));
                        assert_eq!(
                            request.headers()["authorization"],
                            "Bearer idle-test-secret"
                        );
                        let mut body = request.into_body();
                        while let Some(frame) = body.frame().await {
                            let Ok(frame) = frame else {
                                return Ok::<_, Infallible>(Response::new(Empty::<Bytes>::new()));
                            };
                            let data = frame.into_data().unwrap();
                            if !data.is_empty() {
                                bytes.send(data).await.unwrap();
                            }
                        }
                        ended.store(true, Ordering::SeqCst);
                        Ok::<_, Infallible>(Response::new(Empty::<Bytes>::new()))
                    }
                }),
            )
            .await;
    });
    UploadPeer {
        address,
        bytes,
        ended,
        task,
    }
}

#[tokio::test]
async fn real_tls_upload_idle_deadline_resets_and_cancels_upstream() {
    let observations = timeout(Duration::from_secs(55), async {
        let (anthropic, openai) = tokio::join!(idle_upload("anthropic"), idle_upload("openai"));
        [anthropic, openai]
    })
    .await
    .unwrap();
    if let Some(path) = std::env::var_os("COOP_IDLE_OBSERVATIONS") {
        std::fs::write(path, serde_json::to_vec_pretty(&observations).unwrap()).unwrap();
    }
}

async fn idle_upload(provider: &'static str) -> serde_json::Value {
    let fixtures = generate_fixtures();
    let mut peer = upload_peer(fixtures.path(), provider).await;
    let config = serde_json::json!({
        "version": 1, "listen": "127.0.0.1:0", "provider": provider,
        "capability_token": "a".repeat(64),
        "injection": {"scheme": "bearer", "credential": "idle-test-secret"}
    });
    let mut ctx = Ctx::new(ProxyConfig::from_json(&config.to_string()).unwrap()).unwrap();
    ctx.connector = trusted_connector(fixtures.path());
    ctx.upstream_destination = Some(TestDestination::Socket(peer.address));
    let permits = Arc::clone(&ctx.permits);
    let connections = Arc::clone(&ctx.connections);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (stop, stopped) = oneshot::channel();
    let proxy = tokio::spawn(accept_loop(ctx, listener, async {
        let _ = stopped.await;
    }));
    let mut guest = TcpStream::connect(address).await.unwrap();
    let path = if provider == "anthropic" {
        "/v1/messages"
    } else {
        "/v1/responses"
    };
    let started = std::time::Instant::now();
    guest.write_all(format!(
        "POST {path} HTTP/1.1\r\nHost: guest.invalid\r\nAuthorization: Bearer {}\r\nContent-Length: 3\r\n\r\na",
        "a".repeat(64)
    ).as_bytes()).await.unwrap();
    assert_eq!(
        timeout(Duration::from_secs(5), peer.bytes.recv())
            .await
            .unwrap()
            .unwrap(),
        "a"
    );
    tokio::time::sleep(Duration::from_secs(15)).await;
    guest.write_all(b"b").await.unwrap();
    assert_eq!(
        timeout(Duration::from_secs(5), peer.bytes.recv())
            .await
            .unwrap()
            .unwrap(),
        "b"
    );
    let mut response = Vec::new();
    timeout(Duration::from_secs(35), guest.read_to_end(&mut response))
        .await
        .unwrap()
        .unwrap();
    let elapsed_ms = started.elapsed().as_millis();
    assert!(
        (44_000..=51_000).contains(&elapsed_ms),
        "body idle deadline failed to reset: {elapsed_ms}"
    );
    assert!(response.starts_with(b"HTTP/1.1 408 "));
    for secret in ["idle-test-secret".to_owned(), "a".repeat(64)] {
        assert!(
            !response
                .windows(secret.len())
                .any(|part| part == secret.as_bytes())
        );
    }
    timeout(Duration::from_secs(2), peer.task)
        .await
        .unwrap()
        .unwrap();
    assert!(!peer.ended.load(Ordering::SeqCst));
    assert!(peer.bytes.recv().await.is_none());
    timeout(Duration::from_secs(2), async {
        while permits.available_permits() != 256 || connections.available_permits() != 256 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    stop.send(()).unwrap();
    proxy.await.unwrap();
    serde_json::json!({"provider": provider, "status": 408, "upstream_body": [97, 98],
        "upload_complete": peer.ended.load(Ordering::SeqCst), "guest_closed": true,
        "upstream_closed": true, "elapsed_ms": elapsed_ms})
}
