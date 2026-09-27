//! The reverse-proxy request path: verify the guest's capability token,
//! rewrite headers (strip the guest credential, inject the real one, pin the
//! upstream `Host`), and stream the request/response bodies to the fixed
//! upstream over TLS.
//!
//! Everything here is deliberately small and explicit — it is the one
//! component that terminates a connection originated by the untrusted guest
//! and attaches the real credential. The security-critical invariants:
//!
//! - The guest is never authorized unless it presents the exact per-instance
//!   capability token (constant-time compared).
//! - The upstream host and scheme are fixed by the host-side config; only the
//!   request path is taken from the guest (closes SSRF).
//! - The guest's own `authorization` / `x-api-key` (the capability token) is
//!   stripped and replaced with the real credential — it never reaches the
//!   upstream, and the real credential never reaches the guest.
//! - Only the provider-specific method/path operations required by the coding
//!   agents are forwarded; all other authenticated requests are refused
//!   locally before any upstream connection is made.

use std::convert::Infallible;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context as TaskContext, Poll};

use anyhow::{Context, Result};
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use hyper::body::{Body, Bytes, Frame, Incoming, SizeHint};
use hyper::header::{AUTHORIZATION, HOST, HeaderMap, HeaderName, HeaderValue};
use hyper::server::conn::http1::Builder as ServerBuilder;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, Uri};
use hyper_util::rt::{TokioIo, TokioTimer};
use rustls::pki_types::ServerName;
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::{Duration, timeout};
use tokio_rustls::TlsConnector;

use crate::config::{Injection, ProxyConfig};
use crate::request_body::{self, FailureState, Upload};
use crate::{inbound, tls};

/// Fixed upstream port. The guest cannot influence host or port — only the
/// request path is forwarded.
const UPSTREAM_PORT: u16 = 443;

/// How long to wait for the upstream TCP connect + TLS handshake before
/// giving up, so a rogue guest cannot pin host resources on a stuck dial.
const UPSTREAM_TIMEOUT: Duration = Duration::from_secs(30);

/// Cap on concurrently in-flight proxied requests, so a rogue guest cannot
/// exhaust host CPU/memory by opening unbounded upstream connections.
const MAX_CONCURRENT_REQUESTS: usize = 256;

/// Bound guest sockets separately: idle connections never reach the request
/// semaphore, but still consume a host file descriptor and an HTTP task.
const MAX_CONCURRENT_CONNECTIONS: usize = 256;

/// The unified response body: either an upstream stream or a small local
/// error page, both boxed to one type.
type ProxyBody = BoxBody<Bytes, hyper::Error>;

/// A response body that holds its concurrency permit until the body is fully
/// streamed. Without this the permit would drop when the response *headers*
/// arrive, leaving the (possibly minutes-long, streaming) body uncounted — so
/// `MAX_CONCURRENT_REQUESTS` would not actually bound concurrent upstream
/// connections. Attaching the permit here makes the cap effective for a
/// request's whole lifetime.
struct GuardedBody {
    inner: ProxyBody,
    _permit: OwnedSemaphorePermit,
}

impl Body for GuardedBody {
    type Data = Bytes;
    type Error = hyper::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        Pin::new(&mut self.inner).poll_frame(cx)
    }

    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

/// The `x-api-key` header, constructed once.
fn x_api_key() -> HeaderName {
    HeaderName::from_static("x-api-key")
}

#[cfg(test)]
#[derive(Clone, Copy)]
enum TestDestination {
    Socket(std::net::SocketAddr),
    DnsFailure,
}

/// Shared, cheaply-cloneable per-connection state.
#[derive(Clone)]
struct Ctx {
    cfg: Arc<ProxyConfig>,
    connector: TlsConnector,
    permits: Arc<Semaphore>,
    connections: Arc<Semaphore>,
    // Unit-test socket destination only; absent from production binaries and
    // startup JSON. TLS still verifies the compiled provider hostname.
    #[cfg(test)]
    upstream_destination: Option<TestDestination>,
}

impl Ctx {
    fn new(cfg: ProxyConfig) -> Result<Self> {
        let connector = TlsConnector::from(tls::client_config()?);
        Ok(Self {
            cfg: Arc::new(cfg),
            connector,
            permits: Arc::new(Semaphore::new(MAX_CONCURRENT_REQUESTS)),
            connections: Arc::new(Semaphore::new(MAX_CONCURRENT_CONNECTIONS)),
            #[cfg(test)]
            upstream_destination: None,
        })
    }
}

/// Bind the listener and serve until `shutdown` resolves.
///
/// Refuses non-loopback listeners. The guest reaches host loopback through
/// its per-instance reverse SSH tunnel.
///
/// `Ctx::new` runs before the bind so that a bound listener means the proxy can
/// serve — nothing fallible may sit between the bind and `accept_loop`.
pub async fn serve(
    cfg: ProxyConfig,
    shutdown: impl std::future::Future<Output = ()>,
) -> Result<()> {
    let listen = cfg.listen;
    if !listen.ip().is_loopback() {
        anyhow::bail!("refusing non-loopback proxy listener");
    }
    let ctx = Ctx::new(cfg)?;
    let listener = TcpListener::bind(listen)
        .await
        .with_context(|| format!("failed to bind proxy listener on {listen}"))?;
    tracing::info!(
        "coop-proxy listening on {listen} → https://{}",
        ctx.cfg.provider.host()
    );
    accept_loop(ctx, listener, shutdown).await;
    Ok(())
}

async fn accept_loop(
    ctx: Ctx,
    listener: TcpListener,
    shutdown: impl std::future::Future<Output = ()>,
) {
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            () = &mut shutdown => {
                tracing::info!("shutdown requested — no longer accepting connections");
                break;
            }
            accepted = listener.accept() => {
                let stream = match accepted {
                    Ok((stream, _peer)) => stream,
                    Err(e) => {
                        tracing::warn!("accept failed: {e}");
                        // Resource exhaustion can make accept fail immediately;
                        // avoid spinning and filling the host log in that case.
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        continue;
                    }
                };
                let Ok(permit) = ctx.connections.clone().try_acquire_owned() else {
                    drop(stream);
                    continue;
                };
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let mut stream = stream;
                    let prefix = match inbound::read_preface(&mut stream).await {
                        Ok(prefix) => prefix,
                        Err(status) => {
                            inbound::refuse(&mut stream, status).await;
                            return;
                        }
                    };
                    let (reader, writer) = stream.into_split();
                    let reader = std::io::Cursor::new(prefix).chain(reader);
                    let io = TokioIo::new(tokio::io::join(reader, writer));
                    let service = service_fn(move |req| {
                        let ctx = ctx.clone();
                        async move { handle(req, ctx).await }
                    });
                    if let Err(e) = ServerBuilder::new()
                        .keep_alive(false)
                        .timer(TokioTimer::new())
                        .header_read_timeout(Duration::from_secs(10))
                        .max_headers(128)
                        .max_buf_size(64 * 1024)
                        .serve_connection(io, service)
                        .await
                    {
                        tracing::debug!("guest connection error: {e}");
                    }
                });
            }
        }
    }
}

/// A refusal carrying only a fixed, secret-free message.
struct Refusal {
    status: StatusCode,
    msg: &'static str,
}

async fn handle(req: Request<Incoming>, ctx: Ctx) -> Result<Response<ProxyBody>, Infallible> {
    match proxy(req, &ctx).await {
        Ok(resp) => Ok(resp),
        Err(Refusal { status, msg }) => Ok(error_response(status, msg)),
    }
}

async fn proxy(req: Request<Incoming>, ctx: &Ctx) -> Result<Response<ProxyBody>, Refusal> {
    if req
        .headers()
        .iter()
        .any(|(name, value)| name.as_str().len() + value.as_bytes().len() > 16 * 1024)
    {
        return Err(Refusal {
            status: StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE,
            msg: "request header field exceeds limit",
        });
    }
    if !authorized(req.headers(), ctx.cfg.capability_token.expose()) {
        return Err(Refusal {
            status: StatusCode::UNAUTHORIZED,
            msg: "missing or invalid coop-proxy capability token",
        });
    }

    if !operation_allowed(req.method(), req.uri(), ctx.cfg.provider.host()) {
        return Err(Refusal {
            status: StatusCode::FORBIDDEN,
            msg: "operation is not allowed by coop-proxy",
        });
    }

    request_body::validate_headers(req.headers()).map_err(|failure| Refusal {
        status: failure.status(),
        msg: "request body rejected",
    })?;

    // Held until the response body finishes streaming (see `GuardedBody`), so
    // the concurrency cap bounds a request for its whole lifetime.
    let permit = ctx
        .permits
        .clone()
        .try_acquire_owned()
        .map_err(|_| Refusal {
            status: StatusCode::SERVICE_UNAVAILABLE,
            msg: "proxy at capacity",
        })?;

    let (mut parts, body) = req.into_parts();
    parts.headers =
        build_upstream_headers(&parts.headers, ctx.cfg.provider.host(), &ctx.cfg.injection)
            .map_err(|_| Refusal {
                status: StatusCode::BAD_REQUEST,
                msg: "request headers could not be rewritten",
            })?;
    parts.uri = origin_form(&parts.uri).map_err(|_| Refusal {
        status: StatusCode::BAD_REQUEST,
        msg: "invalid request target",
    })?;
    let failure = FailureState::default();
    let upstream_req = Request::from_parts(parts, Upload::new(body, failure.clone()));

    forward(upstream_req, ctx, permit, failure).await
}

/// Whether coop-proxy allows this method/path pair for the fixed upstream.
///
/// Provider operations are deliberately default-deny: the coding agents only
/// need response/message creation and Anthropic token counting, so
/// administrative APIs and stored-resource reads must never inherit the host
/// credential's broader authority. Agent upgrades that require another route
/// must fail with 403 until this policy, its tests, and the documentation are
/// deliberately updated. Codex currently identifies this custom provider as
/// `coop credential proxy`, not `OpenAI`, so its OpenAI-specific
/// `POST /v1/responses/compact` behavior does not apply.
fn operation_allowed(method: &Method, uri: &Uri, upstream_host: &str) -> bool {
    if method != Method::POST || uri.scheme().is_some() || uri.authority().is_some() {
        return false;
    }

    matches!(
        (upstream_host, uri.path()),
        ("api.openai.com", "/v1/responses")
            | (
                "api.anthropic.com",
                "/v1/messages" | "/v1/messages/count_tokens"
            )
    )
}

async fn forward(
    req: Request<Upload<Incoming>>,
    ctx: &Ctx,
    permit: OwnedSemaphorePermit,
    failure: FailureState,
) -> Result<Response<ProxyBody>, Refusal> {
    let host = ctx.cfg.provider.host();
    let server_name = ServerName::try_from(host.to_owned()).map_err(|_| Refusal {
        status: StatusCode::INTERNAL_SERVER_ERROR,
        msg: "configured upstream host is not a valid TLS server name",
    })?;

    let connect = async {
        #[cfg(not(test))]
        let tcp = TcpStream::connect((host, UPSTREAM_PORT)).await?;
        #[cfg(test)]
        let tcp = match ctx.upstream_destination {
            Some(TestDestination::Socket(address)) => TcpStream::connect(address).await?,
            Some(TestDestination::DnsFailure) => {
                TcpStream::connect(("coop-proxy-test.invalid", UPSTREAM_PORT)).await?
            }
            None => TcpStream::connect((host, UPSTREAM_PORT)).await?,
        };
        let _ = tcp.set_nodelay(true);
        ctx.connector.connect(server_name, tcp).await
    };
    let tls_stream = match timeout(UPSTREAM_TIMEOUT, connect).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => {
            tracing::warn!("upstream connect/TLS to {host} failed: {e}");
            return Err(bad_gateway());
        }
        Err(_) => {
            tracing::warn!("upstream connect/TLS to {host} timed out");
            return Err(bad_gateway());
        }
    };

    let (mut sender, conn) = hyper::client::conn::http1::handshake(TokioIo::new(tls_stream))
        .await
        .map_err(|e| {
            tracing::warn!("upstream handshake failed: {e}");
            bad_gateway()
        })?;
    tokio::spawn(async move {
        if let Err(e) = conn.await {
            tracing::debug!("upstream connection closed: {e}");
        }
    });

    let resp = sender.send_request(req).await.map_err(|e| {
        tracing::warn!("upstream request failed: {e}");
        failure.get().map_or_else(bad_gateway, |failure| Refusal {
            status: failure.status(),
            msg: "request body rejected",
        })
    })?;
    downstream_response(resp.map(BodyExt::boxed), permit)
}

#[cfg(test)]
#[path = "forward_tests.rs"]
mod forward_tests;

#[cfg(test)]
#[path = "stream_capacity_tests.rs"]
mod stream_capacity_tests;

#[cfg(test)]
#[path = "upstream_disconnect_tests.rs"]
mod upstream_disconnect_tests;

#[cfg(test)]
#[path = "body_idle_tests.rs"]
mod body_idle_tests;

#[cfg(test)]
#[path = "body_limit_tests.rs"]
mod body_limit_tests;

/// Filter upstream connection metadata while preserving status and streaming
/// body ownership. Invalid nominations produce a local 502 before any upstream
/// response metadata reaches the guest.
fn downstream_response(
    mut response: Response<ProxyBody>,
    permit: OwnedSemaphorePermit,
) -> Result<Response<ProxyBody>, Refusal> {
    *response.headers_mut() =
        filtered_hop_headers(response.headers()).map_err(|_| bad_gateway())?;
    Ok(response.map(|body| {
        GuardedBody {
            inner: body,
            _permit: permit,
        }
        .boxed()
    }))
}

fn bad_gateway() -> Refusal {
    Refusal {
        status: StatusCode::BAD_GATEWAY,
        msg: "upstream request failed",
    }
}

/// Whether the request presents the exact capability token. Constant-time on
/// the token bytes so a timing side-channel cannot recover it.
fn authorized(headers: &HeaderMap, expected: &str) -> bool {
    let mut presented = false;
    for name in [AUTHORIZATION, x_api_key()] {
        let mut values = headers.get_all(&name).iter();
        let Some(value) = values.next() else { continue };
        if values.next().is_some() {
            return false;
        }
        let token = if name == AUTHORIZATION {
            let Ok(value) = value.to_str() else {
                return false;
            };
            let Some(token) = value.strip_prefix("Bearer ") else {
                return false;
            };
            token.as_bytes()
        } else {
            value.as_bytes()
        };
        if !constant_time_eq(token, expected.as_bytes()) {
            return false;
        }
        presented = true;
    }
    presented
}

/// Constant-time byte equality. The early length check leaks only length,
/// which for a fixed-width random token reveals nothing useful.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    use subtle::ConstantTimeEq;
    bool::from(a.ct_eq(b))
}

/// Build the header set sent upstream: drop hop-by-hop headers, drop the
/// guest's `Host` and credential slots, pin the upstream `Host`, and inject
/// the real credential (marked sensitive so hyper never logs it).
fn build_upstream_headers(
    incoming: &HeaderMap,
    upstream_host: &str,
    injection: &Injection,
) -> Result<HeaderMap> {
    let mut out = filtered_hop_headers(incoming)?;
    out.remove(HOST);
    out.remove(AUTHORIZATION);
    out.remove(x_api_key());

    out.insert(
        HOST,
        HeaderValue::from_str(upstream_host)
            .context("upstream host is not a valid header value")?,
    );

    match injection {
        Injection::XApiKey { credential } => {
            let mut value = HeaderValue::from_str(credential.expose())
                .context("credential is not a valid header value")?;
            value.set_sensitive(true);
            out.insert(x_api_key(), value);
        }
        Injection::Bearer { credential } => {
            let mut value = HeaderValue::from_str(&format!("Bearer {}", credential.expose()))
                .context("credential is not a valid header value")?;
            value.set_sensitive(true);
            out.insert(AUTHORIZATION, value);
        }
    }

    Ok(out)
}

/// Remove hop headers and every Connection nomination on either proxy hop.
fn filtered_hop_headers(incoming: &HeaderMap) -> Result<HeaderMap> {
    let nominated: Vec<HeaderName> = incoming
        .get_all("connection")
        .iter()
        .map(|value| value.to_str())
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .flat_map(|value| value.split(','))
        .map(|name| HeaderName::from_bytes(name.trim().as_bytes()))
        .collect::<Result<_, _>>()?;
    let mut out = HeaderMap::with_capacity(incoming.len() + 1);
    for (name, value) in incoming {
        if is_hop_by_hop(name) || nominated.contains(name) {
            continue;
        }
        out.append(name.clone(), value.clone());
    }

    Ok(out)
}

/// Connection-scoped headers that must not be forwarded across the proxy hop.
fn is_hop_by_hop(name: &HeaderName) -> bool {
    const HOP_BY_HOP: [&str; 9] = [
        "connection",
        "proxy-connection",
        "keep-alive",
        "transfer-encoding",
        "te",
        "trailer",
        "upgrade",
        "proxy-authenticate",
        "proxy-authorization",
    ];
    HOP_BY_HOP.contains(&name.as_str())
}

/// Reduce a request URI to origin form (path + query only) for the upstream
/// HTTP/1.1 request line; the upstream host is carried by the `Host` header.
fn origin_form(uri: &Uri) -> Result<Uri> {
    let pq = uri.path_and_query().map_or("/", |p| p.as_str());
    pq.parse::<Uri>().context("invalid path-and-query")
}

fn error_response(status: StatusCode, msg: &'static str) -> Response<ProxyBody> {
    let body = Full::new(Bytes::from_static(msg.as_bytes()))
        .map_err(|never: Infallible| match never {})
        .boxed();
    #[expect(
        clippy::expect_used,
        reason = "status/body are constants; builder cannot fail"
    )]
    Response::builder()
        .status(status)
        .body(body)
        .expect("static error response is always valid")
}

#[cfg(test)]
#[expect(clippy::unwrap_used, reason = "tests")]
mod tests {
    use super::*;

    fn hv(s: &str) -> HeaderValue {
        HeaderValue::from_str(s).unwrap()
    }

    fn api_key_injection(secret: &str) -> Injection {
        let json = format!(r#"{{ "scheme": "x_api_key", "credential": "{secret}" }}"#);
        serde_json::from_str(&json).unwrap()
    }

    fn bearer_injection(secret: &str) -> Injection {
        let json = format!(r#"{{ "scheme": "bearer", "credential": "{secret}" }}"#);
        serde_json::from_str(&json).unwrap()
    }

    #[tokio::test]
    async fn response_filters_connection_metadata_and_preserves_payload() {
        let slots = Arc::new(Semaphore::new(1));
        let permit = slots.clone().try_acquire_owned().unwrap();
        let body = Full::new(Bytes::from_static(b"data: first\n\ndata: second\n\n"))
            .map_err(|never: Infallible| match never {})
            .boxed();
        let mut response = Response::new(body);
        *response.status_mut() = StatusCode::TEMPORARY_REDIRECT;
        for name in [
            "connection",
            "proxy-connection",
            "keep-alive",
            "transfer-encoding",
            "te",
            "trailer",
            "upgrade",
            "proxy-authenticate",
            "proxy-authorization",
        ] {
            response.headers_mut().insert(name, hv("x-private"));
        }
        response.headers_mut().append("connection", hv("X-Second"));
        response.headers_mut().insert("x-private", hv("discard"));
        response.headers_mut().insert("x-second", hv("discard"));
        response
            .headers_mut()
            .insert("location", hv("https://elsewhere.invalid/path"));
        response.headers_mut().append("set-cookie", hv("a=1"));
        response.headers_mut().append("set-cookie", hv("b=2"));
        let response = downstream_response(response, permit).ok().unwrap();
        assert_eq!(response.status(), StatusCode::TEMPORARY_REDIRECT);
        assert_eq!(response.headers().len(), 3);
        assert_eq!(
            response.headers()["location"],
            "https://elsewhere.invalid/path"
        );
        assert_eq!(response.headers().get_all("set-cookie").iter().count(), 2);
        assert_eq!(
            slots.available_permits(),
            0,
            "headers must retain the permit"
        );
        let mut body = response.into_body();
        assert!(!body.is_end_stream());
        assert_eq!(body.size_hint().exact(), Some(27));
        let frame = body.frame().await.unwrap().unwrap();
        assert_eq!(frame.data_ref().unwrap(), "data: first\n\ndata: second\n\n");
        assert!(body.is_end_stream());
        assert_eq!(body.size_hint().exact(), Some(0));
        assert!(body.frame().await.is_none());
        drop(body);
        assert_eq!(slots.available_permits(), 1);
    }

    #[test]
    fn malformed_response_nomination_fails_without_leaking_metadata() {
        for nomination in ["", "x-private,", "x-private,,x-other", "bad header"] {
            let slots = Arc::new(Semaphore::new(1));
            let permit = slots.clone().try_acquire_owned().unwrap();
            let mut response = error_response(StatusCode::OK, "upstream-private-content");
            response.headers_mut().insert("connection", hv(nomination));
            let refusal = downstream_response(response, permit).err().unwrap();
            assert_eq!(refusal.status, StatusCode::BAD_GATEWAY);
            assert_eq!(refusal.msg, "upstream request failed");
            assert_eq!(slots.available_permits(), 1);
        }
    }

    #[tokio::test]
    async fn serve_checks_the_listener_before_binding() {
        let mut cfg = ProxyConfig::from_json(
            r#"{"listen":"127.0.0.1:0","version":1,"provider":"anthropic",
                "capability_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "injection":{"scheme":"x_api_key","credential":"fake"}}"#,
        ).unwrap();
        // Exercise the serving boundary independently of startup decoding.
        cfg.listen = "192.0.2.1:0".parse().unwrap();
        let error = serve(cfg, std::future::ready(())).await.unwrap_err();
        assert_eq!(error.to_string(), "refusing non-loopback proxy listener");
    }

    #[tokio::test]
    async fn admission_rejects_before_upstream_capacity_or_network() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let cfg = ProxyConfig::from_json(
            r#"{"listen":"127.0.0.1:0","version":1,"provider":"anthropic",
                "capability_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "injection":{"scheme":"x_api_key","credential":"fake"}}"#,
        ).unwrap();
        let mut ctx = Ctx::new(cfg).unwrap();
        // Even a mutated gate cannot reach a provider in this test.
        ctx.permits = Arc::new(Semaphore::new(0));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop, stopped) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(accept_loop(ctx, listener, async {
            let _ = stopped.await;
        }));
        let auth = format!("X-Api-Key: {}\r\n", "a".repeat(64));
        for (method, headers, status) in [
            ("GET", auth.clone(), 403),
            ("POST", auth.clone(), 503),
            ("POST", format!("{auth}Content-Length: 67108865\r\n"), 413),
            ("POST", format!("{auth}Trailer: x-extra\r\n"), 400),
            ("GET", format!("X-F: {}\r\n", "x".repeat(16_381)), 401),
            ("GET", format!("X-F: {}\r\n", "x".repeat(16_382)), 431),
        ] {
            let mut client = TcpStream::connect(addr).await.unwrap();
            let request = format!("{method} /v1/messages HTTP/1.1\r\nHost: guest\r\n{headers}\r\n");
            client.write_all(request.as_bytes()).await.unwrap();
            let mut response = String::new();
            timeout(Duration::from_secs(5), client.read_to_string(&mut response))
                .await
                .unwrap()
                .unwrap();
            assert!(
                response.starts_with(&format!("HTTP/1.1 {status} ")),
                "{response}"
            );
        }
        let _ = stop.send(());
        server.await.unwrap();
    }

    #[tokio::test]
    #[expect(
        clippy::expect_used,
        reason = "test deadlines describe the missing behavior"
    )]
    async fn idle_connections_are_bounded_and_released_on_disconnect() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let cfg = ProxyConfig::from_json(
            r#"{
                "listen": "127.0.0.1:0",
                "version": 1,
                "capability_token": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "provider": "anthropic",
                "injection": { "scheme": "x_api_key", "credential": "fake" }
            }"#,
        )
        .unwrap();
        let mut ctx = Ctx::new(cfg).unwrap();
        ctx.connections = Arc::new(Semaphore::new(2));
        let connections = Arc::clone(&ctx.connections);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (stop, stopped) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(accept_loop(ctx, listener, async {
            let _ = stopped.await;
        }));
        let budget = Duration::from_secs(5);
        let mut held = Vec::new();
        // Partial headers hold connection permits without starting requests.
        for _ in 0..2 {
            let mut stream = TcpStream::connect(addr).await.unwrap();
            stream.write_all(b"GET / HTTP/1.1\r\nHost:").await.unwrap();
            held.push(stream);
        }
        timeout(budget, async {
            while connections.available_permits() != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("both partial requests must occupy connection slots");

        let mut excess = TcpStream::connect(addr).await.unwrap();
        let mut byte = [0];
        let n = timeout(budget, excess.read(&mut byte))
            .await
            .expect("excess idle connection must be closed without HTTP input")
            .unwrap();
        assert_eq!(n, 0);

        drop(held);
        // Disconnect releases capacity; wait for a real HTTP response, since
        // connect alone can succeed even while the accept loop refuses sockets.
        timeout(budget, async {
            loop {
                let mut stream = TcpStream::connect(addr).await.unwrap();
                if stream
                    .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    .await
                    .is_ok()
                {
                    let mut response = String::new();
                    if stream.read_to_string(&mut response).await.is_ok()
                        && response.contains("401")
                    {
                        break;
                    }
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("disconnect must release connection capacity");
        let _ = stop.send(());
        server.await.unwrap();
    }

    // ── capability token ─────────────────────────────────────

    #[test]
    fn constant_time_eq_matches_and_differs() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
        assert!(!constant_time_eq(b"", b"x"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn credentials_must_be_unique_and_agree() {
        for name in ["authorization", "x-api-key"] {
            let value = if name == "authorization" {
                "Bearer right"
            } else {
                "right"
            };
            let mut headers = HeaderMap::new();
            headers.append(name, hv(value));
            assert!(authorized(&headers, "right"));
            headers.append(name, hv(value));
            assert!(!authorized(&headers, "right"));
        }
        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, hv("Bearer right"));
        headers.insert("x-api-key", hv("right"));
        assert!(authorized(&headers, "right"));
        for value in ["Bearer wrong", "Basic right", "Bearer ", ""] {
            headers.insert(AUTHORIZATION, hv(value));
            assert!(!authorized(&headers, "right"));
        }
        headers.insert(AUTHORIZATION, hv("Bearer right"));
        headers.insert("x-api-key", hv("wrong"));
        assert!(!authorized(&headers, "right"));
    }

    #[test]
    fn connection_nominated_headers_are_removed() {
        let mut headers = HeaderMap::new();
        headers.append("connection", hv("keep-alive, X-Internal"));
        headers.append("connection", hv("x-second"));
        headers.insert("x-internal", hv("private"));
        headers.insert("x-second", hv("private"));
        headers.insert("content-type", hv("application/json"));
        let out =
            build_upstream_headers(&headers, "api.anthropic.com", &bearer_injection("secret"))
                .unwrap();
        assert!(!out.contains_key("x-internal"));
        assert!(!out.contains_key("x-second"));
        assert_eq!(out["content-type"], "application/json");
        assert_eq!(out[AUTHORIZATION], "Bearer secret");
    }

    #[test]
    fn absolute_targets_cannot_authorize() {
        for target in [
            "https://api.anthropic.com/v1/messages",
            "https://evil.example/v1/messages",
            "evil.example:443",
            "*",
        ] {
            assert!(!operation_allowed(
                &Method::POST,
                &target.parse().unwrap(),
                "api.anthropic.com"
            ));
        }
    }

    #[test]
    fn authorized_gate() {
        let mut h = HeaderMap::new();
        h.insert(AUTHORIZATION, hv("Bearer right"));
        assert!(authorized(&h, "right"));
        assert!(!authorized(&h, "wrong"));
        assert!(!authorized(&HeaderMap::new(), "right"));
    }

    // ── Provider operation policy ──────────────────────────────

    #[test]
    fn openai_allows_only_response_creation() {
        let create: Uri = "/v1/responses".parse().unwrap();
        let create_with_query: Uri = "/v1/responses?foo=bar".parse().unwrap();

        assert!(operation_allowed(&Method::POST, &create, "api.openai.com"));
        assert!(operation_allowed(
            &Method::POST,
            &create_with_query,
            "api.openai.com"
        ));
    }

    #[test]
    fn openai_denies_admin_key_creation() {
        let uri: Uri = "/v1/organization/admin_api_keys".parse().unwrap();
        assert!(!operation_allowed(&Method::POST, &uri, "api.openai.com"));
    }

    #[test]
    fn openai_denies_stored_response_reads() {
        let uri: Uri = "/v1/responses/resp_123".parse().unwrap();
        assert!(!operation_allowed(&Method::GET, &uri, "api.openai.com"));
    }

    #[test]
    fn openai_policy_is_default_deny() {
        for (method, path) in [
            (Method::GET, "/v1/responses"),
            (Method::DELETE, "/v1/responses/resp_123"),
            (Method::POST, "/v1/files"),
            (Method::POST, "/v1/responses/"),
            (Method::TRACE, "/v1/responses"),
        ] {
            let uri: Uri = path.parse().unwrap();
            assert!(
                !operation_allowed(&method, &uri, "api.openai.com"),
                "unexpectedly allowed {method} {path}"
            );
        }
    }

    #[test]
    fn anthropic_allows_message_creation_and_token_counting() {
        for path in ["/v1/messages", "/v1/messages/count_tokens"] {
            let uri: Uri = path.parse().unwrap();
            assert!(operation_allowed(&Method::POST, &uri, "api.anthropic.com"));
        }
    }

    #[test]
    fn anthropic_policy_is_default_deny() {
        for (method, path) in [
            (Method::GET, "/v1/messages"),
            (Method::POST, "/v1/messages/batches"),
            (Method::GET, "/v1/messages/batches/msgbatch_123/results"),
            (Method::POST, "/v1/organizations/invites"),
            (Method::POST, "/v1/messages/"),
        ] {
            let uri: Uri = path.parse().unwrap();
            assert!(
                !operation_allowed(&method, &uri, "api.anthropic.com"),
                "unexpectedly allowed {method} {path}"
            );
        }
    }

    #[test]
    fn provider_operations_cannot_cross_provider_boundaries() {
        let openai_path: Uri = "/v1/responses".parse().unwrap();
        let anthropic_path: Uri = "/v1/messages".parse().unwrap();

        assert!(!operation_allowed(
            &Method::POST,
            &anthropic_path,
            "api.openai.com"
        ));
        assert!(!operation_allowed(
            &Method::POST,
            &openai_path,
            "api.anthropic.com"
        ));
    }

    #[test]
    fn unknown_upstream_has_no_allowed_operations() {
        let uri: Uri = "/v1/messages".parse().unwrap();
        assert!(!operation_allowed(
            &Method::POST,
            &uri,
            "proxy-test.invalid"
        ));
    }

    // ── header rewrite ───────────────────────────────────────

    #[test]
    fn rewrite_strips_guest_credentials_and_injects_api_key() {
        let mut incoming = HeaderMap::new();
        incoming.insert(AUTHORIZATION, hv("Bearer capability-token"));
        incoming.insert("x-api-key", hv("capability-token"));
        incoming.insert("anthropic-version", hv("2023-06-01"));
        incoming.insert("content-type", hv("application/json"));
        incoming.insert(HOST, hv("172.16.0.1:8788"));

        let out = build_upstream_headers(
            &incoming,
            "api.anthropic.com",
            &api_key_injection("sk-real"),
        )
        .unwrap();

        assert_eq!(out.get("x-api-key").unwrap(), "sk-real");
        assert!(
            out.get(AUTHORIZATION).is_none(),
            "guest bearer must be stripped"
        );
        assert_eq!(out.get(HOST).unwrap(), "api.anthropic.com");
        assert_eq!(out.get("anthropic-version").unwrap(), "2023-06-01");
        assert_eq!(out.get("content-type").unwrap(), "application/json");
    }

    #[test]
    fn rewrite_injects_bearer_and_replaces_guest_authorization() {
        let mut incoming = HeaderMap::new();
        incoming.insert(AUTHORIZATION, hv("Bearer capability-token"));
        let out = build_upstream_headers(
            &incoming,
            "api.anthropic.com",
            &bearer_injection("setup-tok"),
        )
        .unwrap();
        assert_eq!(out.get(AUTHORIZATION).unwrap(), "Bearer setup-tok");
        assert!(out.get("x-api-key").is_none());
    }

    #[test]
    fn rewrite_marks_injected_credential_sensitive() {
        let mut incoming = HeaderMap::new();
        incoming.insert(AUTHORIZATION, hv("Bearer t"));
        let out = build_upstream_headers(
            &incoming,
            "api.anthropic.com",
            &api_key_injection("sk-real"),
        )
        .unwrap();
        assert!(out.get("x-api-key").unwrap().is_sensitive());
    }

    #[test]
    fn rewrite_drops_hop_by_hop_headers() {
        let mut incoming = HeaderMap::new();
        incoming.insert(AUTHORIZATION, hv("Bearer t"));
        incoming.insert("connection", hv("keep-alive"));
        incoming.insert("keep-alive", hv("timeout=5"));
        incoming.insert("proxy-authorization", hv("Basic xyz"));
        let out = build_upstream_headers(&incoming, "api.anthropic.com", &api_key_injection("k"))
            .unwrap();
        assert!(out.get("connection").is_none());
        assert!(out.get("keep-alive").is_none());
        assert!(out.get("proxy-authorization").is_none());
    }

    #[test]
    fn rewrite_overrides_guest_host_even_without_incoming_host() {
        let incoming = HeaderMap::new();
        let out = build_upstream_headers(&incoming, "api.anthropic.com", &api_key_injection("k"))
            .unwrap();
        assert_eq!(out.get(HOST).unwrap(), "api.anthropic.com");
    }

    // ── uri origin form ──────────────────────────────────────

    #[test]
    fn origin_form_keeps_path_and_query() {
        let uri: Uri = "http://172.16.0.1:8788/v1/messages?beta=true"
            .parse()
            .unwrap();
        assert_eq!(
            origin_form(&uri).unwrap().to_string(),
            "/v1/messages?beta=true"
        );
    }

    #[test]
    fn origin_form_defaults_empty_path_to_root() {
        let uri: Uri = "http://172.16.0.1:8788".parse().unwrap();
        assert_eq!(origin_form(&uri).unwrap().to_string(), "/");
    }
}
