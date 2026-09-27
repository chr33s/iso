//! Streaming upload bounds. Never retain body frames after passing them on.
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use hyper::StatusCode;
use hyper::body::{Body, Bytes, Frame, SizeHint};
use hyper::header::HeaderMap;
use tokio::time::{Instant, Sleep};

pub const MAX_BYTES: u64 = 64 * 1024 * 1024;
const IDLE: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug)]
pub enum Failure {
    TooLarge,
    LengthRequired,
    Trailers,
    Idle,
    Transport,
}

impl Failure {
    pub fn status(self) -> StatusCode {
        match self {
            Self::LengthRequired => StatusCode::LENGTH_REQUIRED,
            Self::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Self::Trailers | Self::Transport => StatusCode::BAD_REQUEST,
            Self::Idle => StatusCode::REQUEST_TIMEOUT,
        }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("request body rejected")
    }
}
impl std::error::Error for Failure {}

/// Shared with the HTTP sender, which otherwise erases the body error reason.
#[derive(Clone, Default)]
pub struct FailureState(Arc<Mutex<Option<Failure>>>);

impl FailureState {
    pub fn get(&self) -> Option<Failure> {
        *self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
    fn set(&self, failure: Failure) {
        *self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(failure);
    }
}

pub fn validate_headers(headers: &HeaderMap) -> Result<(), Failure> {
    if headers.contains_key("trailer") {
        return Err(Failure::Trailers);
    }
    // Reject unknown-length uploads before opening a credential-bearing upstream.
    if headers.contains_key("transfer-encoding") {
        return Err(Failure::LengthRequired);
    }
    if let Some(value) = headers.get("content-length") {
        let count = value
            .to_str()
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or(Failure::Transport)?;
        if count > MAX_BYTES {
            return Err(Failure::TooLarge);
        }
    }
    Ok(())
}

pub struct Upload<B> {
    inner: B,
    remaining: u64,
    deadline: Pin<Box<Sleep>>,
    failure: FailureState,
    done: bool,
}

impl<B: Body> Upload<B> {
    pub fn new(inner: B, failure: FailureState) -> Self {
        let done = inner.is_end_stream();
        Self {
            inner,
            remaining: MAX_BYTES,
            deadline: Box::pin(tokio::time::sleep(IDLE)),
            failure,
            done,
        }
    }
    fn reject(&mut self, failure: Failure) -> Poll<Option<Result<Frame<Bytes>, Failure>>> {
        self.done = true;
        self.failure.set(failure);
        Poll::Ready(Some(Err(failure)))
    }
}

impl<B: Body<Data = Bytes> + Unpin> Body for Upload<B> {
    type Data = Bytes;
    type Error = Failure;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Failure>>> {
        if self.done {
            return Poll::Ready(None);
        }
        if self.deadline.as_mut().poll(cx).is_ready() {
            return self.reject(Failure::Idle);
        }
        match Pin::new(&mut self.inner).poll_frame(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(None) => {
                self.done = true;
                Poll::Ready(None)
            }
            Poll::Ready(Some(Err(_))) => self.reject(Failure::Transport),
            Poll::Ready(Some(Ok(frame))) => {
                let Some(data) = frame.data_ref() else {
                    return self.reject(Failure::Trailers);
                };
                let bytes = data.len() as u64;
                if bytes > self.remaining {
                    return self.reject(Failure::TooLarge);
                }
                self.remaining -= bytes;
                if bytes != 0 {
                    self.deadline.as_mut().reset(Instant::now() + IDLE);
                }
                Poll::Ready(Some(Ok(frame)))
            }
        }
    }

    fn is_end_stream(&self) -> bool {
        self.done || self.inner.is_end_stream()
    }
    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

#[cfg(test)]
#[expect(clippy::unwrap_used, reason = "test body assertions")]
mod tests {
    use crate::request_body::{Failure, FailureState, MAX_BYTES, Upload, validate_headers};
    use http_body_util::BodyExt;
    use hyper::body::{Body, Bytes, Frame};
    use hyper::header::{HeaderMap, HeaderValue};
    use std::collections::VecDeque;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use std::time::Duration;

    struct Frames(VecDeque<Frame<Bytes>>);
    impl Body for Frames {
        type Data = Bytes;
        type Error = std::convert::Infallible;
        fn poll_frame(
            mut self: Pin<&mut Self>,
            _: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Bytes>, Self::Error>>> {
            self.0
                .pop_front()
                .map_or(Poll::Pending, |frame| Poll::Ready(Some(Ok(frame))))
        }
    }

    #[test]
    fn declared_limits_and_trailers() {
        let mut headers = HeaderMap::new();
        assert!(validate_headers(&headers).is_ok());
        headers.insert("content-length", HeaderValue::from(MAX_BYTES));
        assert!(validate_headers(&headers).is_ok());
        headers.insert("content-length", HeaderValue::from(MAX_BYTES + 1));
        assert!(matches!(validate_headers(&headers), Err(Failure::TooLarge)));
        headers.remove("content-length");
        headers.insert("trailer", HeaderValue::from_static("x-extra"));
        assert!(matches!(validate_headers(&headers), Err(Failure::Trailers)));
    }

    #[test]
    fn unknown_length_requires_declared_framing() {
        let mut headers = HeaderMap::new();
        headers.insert("transfer-encoding", HeaderValue::from_static("chunked"));
        let failure = validate_headers(&headers).unwrap_err();
        assert!(matches!(failure, Failure::LengthRequired));
        assert_eq!(failure.status(), hyper::StatusCode::LENGTH_REQUIRED);
    }

    #[tokio::test]
    async fn upload_preserves_size_and_end_of_stream_metadata() {
        let mut upload = Upload::new(
            http_body_util::Full::new(Bytes::from_static(b"abc")),
            FailureState::default(),
        );
        assert_eq!(upload.size_hint().exact(), Some(3));
        assert!(!upload.is_end_stream());
        assert_eq!(
            upload.frame().await.unwrap().unwrap().data_ref().unwrap(),
            "abc"
        );
        assert_eq!(upload.size_hint().exact(), Some(0));
        assert!(upload.is_end_stream());
        assert!(upload.frame().await.is_none());
    }

    #[tokio::test]
    async fn cap_counts_across_frames_without_forwarding_excess() {
        let chunk = Bytes::from(vec![0x5a; 65536]);
        let frames = (0..1024)
            .map(|_| Frame::data(chunk.clone()))
            .chain([Frame::data(Bytes::from_static(b"x"))])
            .collect();
        let failure = FailureState::default();
        let mut upload = Upload::new(Frames(frames), failure.clone());
        for _ in 0..1024 {
            let frame = upload.frame().await.unwrap().unwrap();
            assert_eq!(frame.data_ref(), Some(&chunk));
        }
        assert!(matches!(upload.frame().await, Some(Err(Failure::TooLarge))));
        assert!(matches!(failure.get(), Some(Failure::TooLarge)));
        assert!(upload.frame().await.is_none());
    }

    #[tokio::test]
    async fn undeclared_trailers_never_pass_through() {
        let mut trailers = HeaderMap::new();
        trailers.insert("x-extra", HeaderValue::from_static("private"));
        let failure = FailureState::default();
        let mut upload = Upload::new(Frames([Frame::trailers(trailers)].into()), failure.clone());
        assert!(matches!(upload.frame().await, Some(Err(Failure::Trailers))));
        assert!(matches!(failure.get(), Some(Failure::Trailers)));
        assert!(upload.is_end_stream());
    }

    #[tokio::test]
    async fn hyper_sender_preserves_body_failure_reason() {
        use http_body_util::Full;
        use hyper::service::service_fn;
        use hyper::{Request, Response};
        use hyper_util::rt::TokioIo;

        let (client, server) = tokio::io::duplex(4096);
        let server = tokio::spawn(async move {
            let _ = hyper::server::conn::http1::Builder::new()
                .serve_connection(
                    TokioIo::new(server),
                    service_fn(|request: Request<hyper::body::Incoming>| async move {
                        let _ = request.into_body().collect().await;
                        Ok::<_, std::convert::Infallible>(Response::new(Full::new(Bytes::new())))
                    }),
                )
                .await;
        });
        let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(client))
            .await
            .unwrap();
        let driver = tokio::spawn(connection);
        let failure = FailureState::default();
        let frames = [
            Frame::data(Bytes::from_static(b"body")),
            Frame::trailers(HeaderMap::new()),
        ];
        let body = Upload::new(Frames(frames.into()), failure.clone());
        let mut request = Request::new(body);
        *request.method_mut() = hyper::Method::POST;
        request
            .headers_mut()
            .insert("host", HeaderValue::from_static("controlled.invalid"));
        let result =
            tokio::time::timeout(Duration::from_secs(2), sender.send_request(request)).await;
        driver.abort();
        server.abort();
        let _ = driver.await;
        let _ = server.await;
        assert!(result.unwrap().is_err());
        assert!(matches!(failure.get(), Some(Failure::Trailers)));
        assert_eq!(
            failure.get().unwrap().status(),
            hyper::StatusCode::BAD_REQUEST
        );
    }

    #[tokio::test(start_paused = true)]
    async fn idle_deadline_resets_only_on_data_progress() {
        let failure = FailureState::default();
        let mut upload = Upload::new(Frames(VecDeque::new()), failure.clone());
        tokio::time::advance(Duration::from_secs(29)).await;
        upload
            .inner
            .0
            .push_back(Frame::data(Bytes::from_static(b"progress")));
        assert!(upload.frame().await.unwrap().is_ok());
        tokio::time::advance(Duration::from_secs(29)).await;
        upload.inner.0.push_back(Frame::data(Bytes::new()));
        assert!(upload.frame().await.unwrap().is_ok());
        tokio::time::advance(Duration::from_secs(1)).await;
        assert!(matches!(upload.frame().await, Some(Err(Failure::Idle))));
        assert!(matches!(failure.get(), Some(Failure::Idle)));
    }
}
