//! Declared-size and unknown-length admission through the real TLS forwarding path.
#![expect(
    clippy::unwrap_used,
    reason = "controlled fixtures and test assertions"
)]

use std::convert::Infallible;
use std::fmt::Write;
use std::sync::{Arc, Mutex};

use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::time::{Duration, timeout};
use tokio_rustls::TlsAcceptor;

use crate::config::ProxyConfig;
use crate::proxy::forward_tests::{generate_fixtures, trusted_connector};
use crate::proxy::{Ctx, TestDestination, accept_loop};

const CAP: usize = 64 * 1024 * 1024;

#[derive(Default)]
struct Observed {
    connections: usize,
    requests: usize,
    bytes: usize,
    digest: Option<String>,
    closed: usize,
}

struct Peer {
    address: std::net::SocketAddr,
    observed: Arc<Mutex<Observed>>,
    stop: oneshot::Sender<()>,
    task: tokio::task::JoinHandle<()>,
}

fn hex_digest(hasher: Sha256) -> String {
    let mut output = String::with_capacity(64);
    for byte in hasher.finalize() {
        write!(output, "{byte:02x}").unwrap();
    }
    output
}

async fn peer(fixtures: &std::path::Path, provider: &'static str) -> Peer {
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
    let observed = Arc::new(Mutex::new(Observed::default()));
    let state = Arc::clone(&observed);
    let (stop, mut stopped) = oneshot::channel();
    let task = tokio::spawn(async move {
        let mut children = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                _ = &mut stopped => break,
                socket = listener.accept() => {
                    state.lock().unwrap().connections += 1;
                    let state = Arc::clone(&state);
                    let acceptor = acceptor.clone();
                    children.spawn(async move {
                        let tls = acceptor.accept(socket.unwrap().0).await.unwrap();
                        let requests = Arc::clone(&state);
                        let _ = hyper::server::conn::http1::Builder::new()
                            .serve_connection(TokioIo::new(tls), service_fn(move |request: Request<Incoming>| {
                                receive_body(request, provider, Arc::clone(&requests))
                            })).await;
                        state.lock().unwrap().closed += 1;
                    });
                }
            }
        }
        while let Some(child) = children.join_next().await {
            child.unwrap();
        }
    });
    Peer {
        address,
        observed,
        stop,
        task,
    }
}

async fn receive_body(
    request: Request<Incoming>,
    provider: &str,
    observed: Arc<Mutex<Observed>>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    assert_eq!(request.headers()["host"], format!("api.{provider}.com"));
    assert_eq!(
        request.headers()["authorization"],
        "Bearer limit-test-secret"
    );
    observed.lock().unwrap().requests += 1;
    let mut body = request.into_body();
    let mut hasher = Sha256::new();
    while let Some(frame) = body.frame().await {
        let data = frame.unwrap().into_data().unwrap();
        hasher.update(&data);
        observed.lock().unwrap().bytes += data.len();
    }
    observed.lock().unwrap().digest = Some(hex_digest(hasher));
    Ok(Response::new(Full::new(Bytes::from_static(b"accepted"))))
}

#[tokio::test]
async fn real_tls_declared_body_limit_accepts_exact_and_refuses_excess() {
    let fixtures = generate_fixtures();
    let mut observations = Vec::new();
    for provider in ["anthropic", "openai"] {
        for declared in [Some(CAP), Some(CAP + 1), None] {
            observations.push(
                timeout(
                    Duration::from_secs(30),
                    body_limit(provider, declared, fixtures.path()),
                )
                .await
                .unwrap(),
            );
        }
    }
    if let Some(path) = std::env::var_os("COOP_BODY_LIMIT_OBSERVATIONS") {
        std::fs::write(path, serde_json::to_vec_pretty(&observations).unwrap()).unwrap();
    }
}

async fn body_limit(
    provider: &'static str,
    declared: Option<usize>,
    fixtures: &std::path::Path,
) -> serde_json::Value {
    let peer = peer(fixtures, provider).await;
    let config = serde_json::json!({"version": 1, "listen": "127.0.0.1:0",
        "provider": provider, "capability_token": "a".repeat(64),
        "injection": {"scheme": "bearer", "credential": "limit-test-secret"}});
    let mut ctx = Ctx::new(ProxyConfig::from_json(&config.to_string()).unwrap()).unwrap();
    ctx.connector = trusted_connector(fixtures);
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
    let framing = declared.map_or_else(
        || "Transfer-Encoding: chunked\r\nExpect: 100-continue".to_owned(),
        |count| format!("Content-Length: {count}"),
    );
    guest.write_all(format!(
        "POST {path} HTTP/1.1\r\nHost: guest.invalid\r\nAuthorization: Bearer {}\r\n{framing}\r\n\r\n",
        "a".repeat(64)
    ).as_bytes()).await.unwrap();
    let digest = if declared == Some(CAP) {
        Some(send_body(&mut guest, &peer.observed).await)
    } else {
        None
    };
    let mut response = Vec::new();
    timeout(Duration::from_secs(5), guest.read_to_end(&mut response))
        .await
        .unwrap()
        .unwrap();
    let expected = match declared {
        Some(CAP) => 200,
        Some(_) => 413,
        None => 411,
    };
    assert!(response.starts_with(format!("HTTP/1.1 {expected} ").as_bytes()));
    if declared == Some(CAP) {
        assert!(response.ends_with(b"accepted"));
    }
    for secret in ["limit-test-secret".to_owned(), "a".repeat(64)] {
        assert!(
            !response
                .windows(secret.len())
                .any(|part| part == secret.as_bytes())
        );
    }
    timeout(Duration::from_secs(2), async {
        loop {
            let done = {
                let state = peer.observed.lock().unwrap();
                state.connections == state.closed
            };
            if done && permits.available_permits() == 256 && connections.available_permits() == 256
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    stop.send(()).unwrap();
    proxy.await.unwrap();
    peer.stop.send(()).unwrap();
    peer.task.await.unwrap();
    let observed = peer.observed.lock().unwrap();
    let upstream_count = usize::from(declared == Some(CAP));
    assert_eq!(observed.connections, upstream_count);
    assert_eq!(observed.requests, upstream_count);
    assert_eq!(observed.bytes, if declared == Some(CAP) { CAP } else { 0 });
    assert_eq!(observed.digest, digest);
    serde_json::json!({"provider": provider, "declared_bytes": declared, "status": expected,
        "upstream_connections": observed.connections, "upstream_requests": observed.requests,
        "upstream_body_bytes": observed.bytes, "upstream_sha256": observed.digest,
        "upstream_closed": observed.closed, "guest_closed": true})
}

async fn send_body(guest: &mut TcpStream, observed: &Mutex<Observed>) -> String {
    let mut hasher = Sha256::new();
    let mut chunk = vec![0_u8; 64 * 1024];
    for offset in (0..CAP).step_by(chunk.len()) {
        for (index, byte) in chunk.iter_mut().enumerate() {
            *byte = u8::try_from((offset + index) % 251).unwrap();
        }
        guest.write_all(&chunk).await.unwrap();
        hasher.update(&chunk);
        if offset == 0 {
            timeout(Duration::from_secs(5), async {
                while observed.lock().unwrap().bytes < chunk.len() {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
        }
    }
    hex_digest(hasher)
}
