//! Full local TLS forwarding with synthetic credentials. No provider network IO.
#![expect(
    clippy::unwrap_used,
    reason = "controlled test fixture setup and assertions"
)]

use std::convert::Infallible;
use std::sync::Arc;

use http_body_util::{BodyExt, Full};
use hyper::body::{Bytes, Incoming};
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::time::{Duration, timeout};
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::config::ProxyConfig;
use crate::proxy::{Ctx, TestDestination, accept_loop};

pub(super) fn generate_fixtures() -> tempfile::TempDir {
    let fixtures = tempfile::tempdir().unwrap();
    let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/fixtures/credential-proxy/generate-forwarding-certificates.py");
    let result = std::process::Command::new("python3")
        .arg(script)
        .arg(fixtures.path())
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    fixtures
}

pub(super) fn trusted_connector(fixtures: &std::path::Path) -> TlsConnector {
    let mut roots = rustls::RootCertStore::empty();
    roots
        .add(CertificateDer::from(
            std::fs::read(fixtures.join("forward_ca.der")).unwrap(),
        ))
        .unwrap();
    TlsConnector::from(Arc::new(
        rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    ))
}

#[derive(serde::Deserialize)]
struct ForwardCase {
    id: String,
    certificate: Option<String>,
    trust_anchor: Option<bool>,
    #[serde(default)]
    establishment_failure: bool,
    #[serde(default)]
    stall_handshake: bool,
    #[serde(default)]
    dns_failure: bool,
    minimum_elapsed_ms: Option<u64>,
    maximum_elapsed_ms: Option<u64>,
    provider: String,
    path: String,
    scheme: String,
    response_status: u16,
    response_date: String,
    request_body: String,
    response_body: String,
}

impl ForwardCase {
    fn injected_header(&self) -> (&str, &str) {
        if self.scheme == "bearer" {
            ("authorization", "Bearer test-credential")
        } else {
            ("x-api-key", "test-credential")
        }
    }
}

fn corpus_context(case: &ForwardCase, token: &str, fixtures: &std::path::Path) -> Ctx {
    let config = serde_json::json!({"version": 1, "listen": "127.0.0.1:0",
        "provider": case.provider, "capability_token": token,
        "injection": {"scheme": case.scheme, "credential": "test-credential"}});
    let mut ctx = Ctx::new(ProxyConfig::from_json(&config.to_string()).unwrap()).unwrap();
    if case.trust_anchor.unwrap_or(true) {
        ctx.connector = trusted_connector(fixtures);
    }
    ctx
}

struct MockUpstream {
    address: std::net::SocketAddr,
    observed: tokio::sync::mpsc::Receiver<(hyper::http::request::Parts, Bytes)>,
    task: tokio::task::JoinHandle<()>,
}

async fn mock_upstream(case: &ForwardCase, fixtures: &std::path::Path) -> MockUpstream {
    if case.dns_failure {
        assert!(
            tokio::net::lookup_host(("coop-proxy-test.invalid", 443))
                .await
                .is_err(),
            "DNS fixture must not resolve"
        );
        let (_, observed) = tokio::sync::mpsc::channel(1);
        return MockUpstream {
            address: "127.0.0.1:1".parse().unwrap(),
            observed,
            task: tokio::spawn(async {}),
        };
    }
    let status = case.response_status;
    let stall = case.stall_handshake;
    let body = case.response_body.clone();
    let date = case.response_date.clone();
    let server_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(
                std::fs::read(fixtures.join(format!(
                    "{}.der",
                    case.certificate.as_deref().unwrap_or("forward_leaf")
                )))
                .unwrap(),
            )],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
                std::fs::read(fixtures.join("forward_leaf.pkcs8.der")).unwrap(),
            )),
        )
        .unwrap();
    let acceptor = TlsAcceptor::from(Arc::new(server_config));
    let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = upstream.local_addr().unwrap();
    let (observed_tx, observed_rx) = tokio::sync::mpsc::channel(1);
    let upstream_task = tokio::spawn(async move {
        let (mut socket, _) = upstream.accept().await.unwrap();
        if stall {
            use tokio::io::AsyncReadExt;
            let mut buffer = [0_u8; 4096];
            while socket.read(&mut buffer).await.unwrap() != 0 {}
            return;
        }
        let Ok(tls) = acceptor.accept(socket).await else {
            return;
        };
        hyper::server::conn::http1::Builder::new()
            .serve_connection(
                TokioIo::new(tls),
                service_fn(move |request: Request<Incoming>| {
                    let observed = observed_tx.clone();
                    let body = body.clone();
                    let date = date.clone();
                    async move {
                        let (parts, incoming) = request.into_parts();
                        let bytes = incoming.collect().await.unwrap().to_bytes();
                        observed.send((parts, bytes)).await.unwrap();
                        let response = Response::builder()
                            .status(status)
                            .header("date", date)
                            .header("location", "https://unreached.invalid/redirect")
                            .header("connection", "x-private, close")
                            .header("x-private", "must-strip")
                            .header("content-encoding", "gzip")
                            .header("set-cookie", "a=1")
                            .header("set-cookie", "b=2")
                            .body(Full::new(Bytes::from(body)))
                            .unwrap();
                        Ok::<_, Infallible>(response)
                    }
                }),
            )
            .await
            .unwrap();
    });
    MockUpstream {
        address,
        observed: observed_rx,
        task: upstream_task,
    }
}

#[tokio::test]
async fn forwards_to_verified_tls_and_preserves_provider_response() {
    let fixtures = generate_fixtures();
    let cases: Vec<ForwardCase> = serde_json::from_str(include_str!(
        "../../tests/fixtures/credential-proxy/forwarding.json"
    ))
    .unwrap();
    let mut observations = Vec::new();
    for case in cases {
        let token = "a".repeat(64);
        let mut ctx = corpus_context(&case, &token, fixtures.path());
        let MockUpstream {
            address: upstream_address,
            observed: mut observed_rx,
            task: upstream_task,
        } = mock_upstream(&case, fixtures.path()).await;
        ctx.upstream_destination = Some(if case.dns_failure {
            TestDestination::DnsFailure
        } else {
            TestDestination::Socket(upstream_address)
        });
        let downstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = downstream.local_addr().unwrap();
        let (stop, stopped) = oneshot::channel();
        let proxy_task = tokio::spawn(accept_loop(ctx, downstream, async {
            let _ = stopped.await;
        }));
        let started = std::time::Instant::now();
        let response = raw_guest_exchange(address, &case, &token).await;
        let elapsed_ms = started.elapsed().as_millis();
        if case.establishment_failure {
            assert_eq!(response.status(), 502, "{}", case.id);
            assert!(
                timeout(Duration::from_secs(2), observed_rx.recv())
                    .await
                    .unwrap()
                    .is_none(),
                "TLS failure must prevent HTTP credential delivery"
            );
            for secret in [token.as_bytes(), b"test-credential".as_slice()] {
                assert!(
                    !response
                        .body()
                        .windows(secret.len())
                        .any(|bytes| bytes == secret)
                );
            }
            observations.push(serde_json::json!({"id": case.id, "upstream_count": 0,
                "response_status": response.status().as_u16(), "connection_closed": true}));
        } else {
            assert_response(&response, &case);
            let response_status = response.status().as_u16();
            let response_headers = observed_headers(response.headers());
            let response_body = response.into_body();
            assert_eq!(response_body, case.response_body);
            let (parts, body) = timeout(Duration::from_secs(5), observed_rx.recv())
                .await
                .unwrap()
                .unwrap();
            assert_request(&parts, &body, &case, &token);
            observations.push(serde_json::json!({
            "id": case.id, "upstream_count": 1, "connection_closed": true, "method": parts.method.as_str(),
            "path": parts.uri.to_string(), "request_headers": observed_headers(&parts.headers),
            "request_body": body.to_vec(), "response_status": response_status,
            "response_headers": response_headers, "response_body": response_body.to_vec(),
        }));
        }
        if case.stall_handshake {
            assert!(
                elapsed_ms >= u128::from(case.minimum_elapsed_ms.unwrap()),
                "deadline fired early"
            );
            assert!(
                elapsed_ms <= u128::from(case.maximum_elapsed_ms.unwrap()),
                "deadline fired late"
            );
            let observation = observations.last_mut().unwrap();
            observation["elapsed_ms"] = serde_json::json!(elapsed_ms);
            observation["upstream_closed"] = serde_json::json!(true);
        }
        let _ = stop.send(());
        timeout(Duration::from_secs(5), upstream_task)
            .await
            .unwrap()
            .unwrap();
        timeout(Duration::from_secs(5), proxy_task)
            .await
            .unwrap()
            .unwrap();
    }
    if let Some(path) = std::env::var_os("COOP_FORWARD_OBSERVATIONS") {
        std::fs::write(path, serde_json::to_vec_pretty(&observations).unwrap()).unwrap();
    }
}

fn observed_headers(headers: &hyper::HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .map(|(name, value)| (name.as_str().to_owned(), value.to_str().unwrap().to_owned()))
        .collect()
}

fn assert_response(response: &Response<Bytes>, case: &ForwardCase) {
    assert_eq!(
        response.status().as_u16(),
        case.response_status,
        "{}",
        case.id
    );
    assert_eq!(
        response.headers()["location"],
        "https://unreached.invalid/redirect"
    );
    assert!(!response.headers().contains_key("x-private"));
    assert_eq!(response.headers()["content-encoding"], "gzip");
    assert_eq!(response.headers().get_all("set-cookie").iter().count(), 2);
}

fn assert_request(
    parts: &hyper::http::request::Parts,
    body: &Bytes,
    case: &ForwardCase,
    token: &str,
) {
    let (credential_header, credential_value) = case.injected_header();
    assert_eq!(parts.method, "POST");
    assert_eq!(parts.uri.to_string(), case.path);
    assert_eq!(parts.headers["host"], format!("api.{}.com", case.provider));
    assert_eq!(parts.headers[credential_header], credential_value);
    assert!(!parts.headers.contains_key("x-guest"));
    assert!(!parts.headers.values().any(|value| {
        value
            .as_bytes()
            .windows(token.len())
            .any(|bytes| bytes == token.as_bytes())
    }));
    assert_eq!(body.as_ref(), case.request_body.as_bytes());
}

/// Keep the client write side open and require peer EOF after the full response.
async fn raw_guest_exchange(
    address: std::net::SocketAddr,
    case: &ForwardCase,
    token: &str,
) -> Response<Bytes> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut socket = TcpStream::connect(address).await.unwrap();
    let request = format!(
        "POST {} HTTP/1.1\r\nHost: guest-controlled.invalid\r\nAuthorization: Bearer {token}\r\nX-Api-Key: {token}\r\nConnection: x-guest, authorization, host\r\nX-Guest: must-strip\r\nContent-Length: {}\r\n\r\n{}",
        case.path,
        case.request_body.len(),
        case.request_body
    );
    socket.write_all(request.as_bytes()).await.unwrap();
    let mut wire = Vec::new();
    timeout(
        Duration::from_millis(case.maximum_elapsed_ms.unwrap_or(5000)),
        socket.read_to_end(&mut wire),
    )
    .await
    .unwrap()
    .unwrap();
    let mut headers = [httparse::EMPTY_HEADER; 128];
    let mut parsed = httparse::Response::new(&mut headers);
    let head_bytes = parsed.parse(&wire).unwrap().unwrap();
    let mut response = Response::builder().status(parsed.code.unwrap());
    for header in parsed.headers.iter() {
        response = response.header(header.name, header.value);
    }
    let response = response
        .body(Bytes::copy_from_slice(&wire[head_bytes..]))
        .unwrap();
    assert!(!response.headers().contains_key("transfer-encoding"));
    let length: usize = response.headers()["content-length"]
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(
        response.body().len(),
        length,
        "exactly one complete response before EOF"
    );
    response
}
