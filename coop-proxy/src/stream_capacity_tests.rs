//! Real TLS streams hold production request and connection capacity.
#![expect(
    clippy::unwrap_used,
    reason = "controlled fixtures and test assertions"
)]

use std::convert::Infallible;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Context, Poll};

use http_body_util::{BodyExt, Empty};
use hyper::body::{Body, Bytes, Frame, Incoming};
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

const FIRST: &[u8] = b"data: held\n\n";
const LAST: &[u8] = b"data: finished\n\n";

struct StreamingBody(mpsc::Receiver<Bytes>);

impl Body for StreamingBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        self.0
            .poll_recv(cx)
            .map(|part| part.map(|bytes| Ok(Frame::data(bytes))))
    }
}

struct Guest {
    body: Incoming,
    // Keep the client sender alive so it cannot initiate connection closure.
    _sender: hyper::client::conn::http1::SendRequest<Empty<Bytes>>,
    driver: tokio::task::JoinHandle<Result<(), hyper::Error>>,
    upstream: mpsc::Sender<Bytes>,
}

async fn guest(
    address: std::net::SocketAddr,
    controls: &mut mpsc::Receiver<mpsc::Sender<Bytes>>,
    provider: &str,
) -> Guest {
    let socket = TcpStream::connect(address).await.unwrap();
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(socket))
        .await
        .unwrap();
    let driver = tokio::spawn(connection);
    let request = Request::post(operation(provider))
        .header("host", "guest.invalid")
        .header("authorization", format!("Bearer {}", "a".repeat(64)))
        .body(Empty::<Bytes>::new())
        .unwrap();
    let response = sender.send_request(request).await.unwrap();
    assert_eq!(response.status(), 200);
    let mut body = response.into_body();
    assert_eq!(
        body.frame().await.unwrap().unwrap().into_data().unwrap(),
        FIRST
    );
    Guest {
        body,
        _sender: sender,
        driver,
        upstream: controls.recv().await.unwrap(),
    }
}

#[tokio::test]
async fn real_tls_streams_hold_256_slots_until_completion_or_disconnect() {
    let mut observations = Vec::new();
    for provider in ["anthropic", "openai"] {
        observations.extend(
            timeout(Duration::from_secs(60), capacity_scenario(provider))
                .await
                .unwrap(),
        );
    }
    if let Some(path) = std::env::var_os("COOP_STREAM_OBSERVATIONS") {
        std::fs::write(path, serde_json::to_vec_pretty(&observations).unwrap()).unwrap();
    }
}

struct Upstream {
    address: std::net::SocketAddr,
    observed: mpsc::Receiver<mpsc::Sender<Bytes>>,
    closed: Arc<AtomicUsize>,
    requests: Arc<AtomicUsize>,
    stop: oneshot::Sender<()>,
    task: tokio::task::JoinHandle<()>,
}

async fn upstream(fixtures: &std::path::Path, provider: &'static str) -> Upstream {
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
    let upstream_address = listener.local_addr().unwrap();
    let (controls, observed) = mpsc::channel(256);
    let closed = Arc::new(AtomicUsize::new(0));
    let closed_count = Arc::clone(&closed);
    let requests = Arc::new(AtomicUsize::new(0));
    let request_count = Arc::clone(&requests);
    let (stop_upstream, mut stopped_upstream) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                _ = &mut stopped_upstream => break,
                accepted = listener.accept() => {
                    let socket = accepted.unwrap().0;
                    let acceptor = acceptor.clone();
                    let controls = controls.clone();
                    let closed = Arc::clone(&closed_count);
                    let requests = Arc::clone(&request_count);
                    connections.spawn(async move {
                        let tls = acceptor.accept(socket).await.unwrap();
                        let _ = hyper::server::conn::http1::Builder::new()
                            .serve_connection(TokioIo::new(tls), service_fn(move |request: Request<Incoming>| {
                                let controls = controls.clone();
                                requests.fetch_add(1, Ordering::SeqCst);
                                async move {
                                    assert_eq!(request.headers()["host"], format!("api.{provider}.com"));
                                    assert_eq!(request.headers()["authorization"], "Bearer stream-test-secret");
                                    assert_eq!(request.uri(), operation(provider));
                                    assert!(request.into_body().collect().await.unwrap().to_bytes().is_empty());
                                    let (sender, receiver) = mpsc::channel(2);
                                    sender.send(Bytes::from_static(FIRST)).await.unwrap();
                                    controls.send(sender).await.unwrap();
                                    Ok::<_, Infallible>(Response::new(StreamingBody(receiver)))
                                }
                            })).await;
                        closed.fetch_add(1, Ordering::SeqCst);
                    });
                }
            }
        }
        while let Some(result) = connections.join_next().await {
            result.unwrap();
        }
    });
    Upstream {
        address: upstream_address,
        observed,
        closed,
        requests,
        stop: stop_upstream,
        task: upstream,
    }
}

fn operation(provider: &str) -> &str {
    if provider == "anthropic" {
        "/v1/messages"
    } else {
        "/v1/responses"
    }
}

async fn capacity_scenario(provider: &'static str) -> Vec<serde_json::Value> {
    let fixtures = generate_fixtures();
    let Upstream {
        address: upstream_address,
        mut observed,
        closed,
        requests,
        stop: stop_upstream,
        task: upstream,
    } = upstream(fixtures.path(), provider).await;
    let cfg = ProxyConfig::from_json(
        &serde_json::json!({
            "version": 1, "listen": "127.0.0.1:0", "provider": provider,
            "capability_token": "a".repeat(64),
            "injection": {"scheme": "bearer", "credential": "stream-test-secret"}
        })
        .to_string(),
    )
    .unwrap();
    let mut ctx = Ctx::new(cfg).unwrap();
    ctx.connector = trusted_connector(fixtures.path());
    ctx.upstream_destination = Some(TestDestination::Socket(upstream_address));
    let permits = Arc::clone(&ctx.permits);
    let connections = Arc::clone(&ctx.connections);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (stop, stopped) = oneshot::channel();
    let proxy = tokio::spawn(accept_loop(ctx, listener, async {
        let _ = stopped.await;
    }));

    let mut observations = Vec::new();
    for (round, disconnect) in [true, false, true].into_iter().enumerate() {
        let requests_before = requests.load(Ordering::SeqCst);
        let closed_before = closed.load(Ordering::SeqCst);
        let mut guests = Vec::new();
        for _ in 0..256 {
            guests.push(guest(address, &mut observed, provider).await);
        }
        assert_eq!(
            permits.available_permits(),
            0,
            "response headers/body chunks must retain all request slots"
        );
        assert_eq!(connections.available_permits(), 0);
        let received = refuse_excess(address, provider).await;
        assert!(
            observed.try_recv().is_err(),
            "excess request reached upstream"
        );
        let held_duration_ms = if disconnect {
            0
        } else {
            hold_sse(&permits, &connections, &closed, closed_before).await
        };
        let held_responses = guests.len();
        let mut completed_responses = 0;
        for guest in guests {
            if disconnect {
                guest.driver.abort();
                assert!(guest.driver.await.unwrap_err().is_cancelled());
            } else {
                guest.upstream.send(Bytes::from_static(LAST)).await.unwrap();
                drop(guest.upstream);
                assert_eq!(guest.body.collect().await.unwrap().to_bytes(), LAST);
                // The sender remains alive while the driver observes proxy EOF.
                guest.driver.await.unwrap().unwrap();
                completed_responses += 1;
            }
        }
        timeout(Duration::from_secs(5), async {
            while permits.available_permits() != 256
                || connections.available_permits() != 256
                || closed.load(Ordering::SeqCst) != (round + 1) * 256
            {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        observations.push(serde_json::json!({
            "provider": provider, "round": round,
            "termination": if disconnect { "disconnect" } else { "complete" },
            "held_responses": held_responses,
            "upstream_requests": requests.load(Ordering::SeqCst) - requests_before,
            "upstream_closed": closed.load(Ordering::SeqCst) - closed_before,
            "excess_response_bytes": received, "completed_responses": completed_responses,
            "held_duration_ms": held_duration_ms
        }));
    }
    stop.send(()).unwrap();
    proxy.await.unwrap();
    stop_upstream.send(()).unwrap();
    upstream.await.unwrap();
    observations
}

async fn refuse_excess(address: std::net::SocketAddr, provider: &str) -> usize {
    let mut excess = TcpStream::connect(address).await.unwrap();
    let request = format!(
        "POST {} HTTP/1.1\r\nHost: guest.invalid\r\nAuthorization: Bearer {}\r\nContent-Length: 0\r\n\r\n",
        operation(provider),
        "a".repeat(64)
    );
    if let Err(error) = excess.write_all(request.as_bytes()).await {
        assert!(matches!(
            error.kind(),
            std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset
        ));
    }
    let received = timeout(Duration::from_secs(1), excess.read(&mut [0]))
        .await
        .unwrap();
    let received = match received {
        Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => 0,
        result => result.unwrap(),
    };
    assert_eq!(received, 0);
    received
}

async fn hold_sse(
    permits: &tokio::sync::Semaphore,
    connections: &tokio::sync::Semaphore,
    closed: &AtomicUsize,
    closed_before: usize,
) -> u128 {
    let started = std::time::Instant::now();
    tokio::time::sleep(Duration::from_secs(31)).await;
    assert_eq!(
        permits.available_permits(),
        0,
        "long SSE responses lost their request permits"
    );
    assert_eq!(
        connections.available_permits(),
        0,
        "long SSE responses closed early"
    );
    assert_eq!(
        closed.load(Ordering::SeqCst),
        closed_before,
        "upstream closed before final SSE chunk"
    );
    started.elapsed().as_millis()
}
