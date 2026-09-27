//! Validate raw HTTP metadata before Hyper normalizes the URI and framing
//! headers. httparse owns parsing; Hyper still owns all body framing/streaming.
use hyper::StatusCode;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::{Duration, timeout};

const FIELD_BYTES: usize = 16 * 1024;
const HEADER_BYTES: usize = 64 * 1024;
const HEADER_COUNT: usize = 128;
// Reserve bounded wire overhead for optional whitespace and separators in
// addition to parsed metadata. Keep this aligned with Swift's headerWireBytes.
const PREFACE_BYTES: usize = HEADER_BYTES + FIELD_BYTES + HEADER_COUNT * 4 + 64;

pub async fn read_preface(stream: &mut TcpStream) -> Result<Vec<u8>, StatusCode> {
    timeout(Duration::from_secs(10), async {
        let mut bytes = Vec::with_capacity(4096);
        loop {
            let mut headers = [httparse::EMPTY_HEADER; HEADER_COUNT];
            let mut request = httparse::Request::new(&mut headers);
            match request.parse(&bytes) {
                Ok(httparse::Status::Complete(_)) => {
                    validate_head(&request)?;
                    return Ok(bytes);
                }
                Ok(httparse::Status::Partial) => {
                    enforce_partial_field_budget(&bytes, request.path)?;
                }
                Err(httparse::Error::TooManyHeaders) => {
                    return Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE);
                }
                Err(_) => return Err(StatusCode::BAD_REQUEST),
            }
            if bytes.len() >= PREFACE_BYTES {
                return Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE);
            }
            let mut chunk = [0; 4096];
            let remaining = (PREFACE_BYTES - bytes.len()).min(chunk.len());
            let n = stream
                .read(&mut chunk[..remaining])
                .await
                .map_err(|_| StatusCode::BAD_REQUEST)?;
            if n == 0 {
                return Err(StatusCode::BAD_REQUEST);
            }
            bytes.extend_from_slice(&chunk[..n]);
        }
    })
    .await
    .map_err(|_| StatusCode::REQUEST_TIMEOUT)?
}

/// Bound unfinished fields before httparse can return a complete request.
/// This only accounts for bytes; httparse remains the syntax/framing parser.
fn enforce_partial_field_budget(bytes: &[u8], target: Option<&str>) -> Result<(), StatusCode> {
    let mut total = target.map_or(0, str::len);
    for line in bytes.split(|byte| *byte == b'\n').skip(1) {
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.is_empty() {
            continue;
        }
        let size = match line.iter().position(|byte| *byte == b':') {
            Some(colon) => {
                let value = line[colon + 1..].trim_ascii_start();
                colon + value.len()
            }
            None => line.len(),
        };
        total += size;
        if size > FIELD_BYTES || total > HEADER_BYTES {
            return Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE);
        }
    }
    Ok(())
}

fn validate_head(request: &httparse::Request<'_, '_>) -> Result<(), StatusCode> {
    if request.version != Some(1) {
        return Err(StatusCode::HTTP_VERSION_NOT_SUPPORTED);
    }
    let target = request.path.ok_or(StatusCode::BAD_REQUEST)?;
    if target.len() > FIELD_BYTES {
        return Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE);
    }
    if !valid_target(target) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let mut total = target.len();
    let mut lengths = 0;
    let mut transfer_encoding = false;
    for header in request.headers.iter() {
        let size = header.name.len() + header.value.len();
        total += size;
        if size > FIELD_BYTES || total > HEADER_BYTES {
            return Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE);
        }
        if header.name.eq_ignore_ascii_case("content-length") {
            lengths += 1;
        }
        if header.name.eq_ignore_ascii_case("transfer-encoding") {
            transfer_encoding = true;
        }
    }
    if lengths > 1 || (lengths != 0 && transfer_encoding) {
        return Err(StatusCode::BAD_REQUEST);
    }
    Ok(())
}

fn valid_target(target: &str) -> bool {
    let bytes = target.as_bytes();
    if !target.starts_with('/') || target.starts_with("//") {
        return false;
    }
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if !(33..=126).contains(&byte) || byte == b'#' || byte == b'\\' {
            return false;
        }
        if byte == b'%' {
            if index + 2 >= bytes.len()
                || !bytes[index + 1].is_ascii_hexdigit()
                || !bytes[index + 2].is_ascii_hexdigit()
            {
                return false;
            }
            index += 3;
        } else {
            index += 1;
        }
    }
    true
}

pub async fn refuse(stream: &mut TcpStream, status: StatusCode) {
    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        status.as_u16(),
        status.canonical_reason().unwrap_or("Bad Request")
    );
    let _ = timeout(
        Duration::from_secs(1),
        stream.write_all(response.as_bytes()),
    )
    .await;
}

#[cfg(test)]
mod tests {
    use crate::inbound::valid_target;

    #[test]
    fn unfinished_fields_and_aggregate_are_bounded() {
        use crate::inbound::{FIELD_BYTES, enforce_partial_field_budget};
        let prefix = "GET / HTTP/1.1\r\nX: ";
        let exact = format!("{prefix}{}", "x".repeat(FIELD_BYTES - 1));
        assert!(enforce_partial_field_budget(exact.as_bytes(), Some("/")).is_ok());
        assert!(enforce_partial_field_budget(format!("{exact}x").as_bytes(), Some("/")).is_err());
        let mut block = String::from("GET / HTTP/1.1\r\n");
        let field = format!("X: {}\r\n", "x".repeat(FIELD_BYTES - 1));
        for _ in 0..3 {
            block.push_str(&field);
        }
        block.push_str("X: ");
        block.push_str(&"x".repeat(FIELD_BYTES - 2));
        block.push_str("\r\n");
        assert!(enforce_partial_field_budget(block.as_bytes(), Some("/")).is_ok());
        block.push('X');
        assert!(enforce_partial_field_budget(block.as_bytes(), Some("/")).is_err());
    }

    #[test]
    #[expect(
        clippy::unwrap_used,
        reason = "parse test requests and inspect rejection statuses"
    )]
    fn complete_head_enforces_each_limit_and_framing_rule() {
        use hyper::StatusCode;

        let field = format!("X-F: {}\r\n", "x".repeat(16_381));
        let cases = [
            (format!("GET / HTTP/1.1\r\n{field}\r\n"), Ok(())),
            (
                format!("GET / HTTP/1.1\r\nX-F: {}\r\n\r\n", "x".repeat(16_382)),
                Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE),
            ),
            (
                format!("GET / HTTP/1.1\r\n{}\r\n", field.repeat(4)),
                Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE),
            ),
            (
                format!("GET / HTTP/1.1\r\n{}X: y\r\n\r\n", field.repeat(4)),
                Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE),
            ),
            (
                format!("GET /{} HTTP/1.1\r\n\r\n", "x".repeat(16_383)),
                Ok(()),
            ),
            (
                format!("GET /{} HTTP/1.1\r\n\r\n", "x".repeat(16_384)),
                Err(StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE),
            ),
            (
                "GET / HTTP/1.0\r\n\r\n".into(),
                Err(StatusCode::HTTP_VERSION_NOT_SUPPORTED),
            ),
            (
                "GET https://evil/ HTTP/1.1\r\n\r\n".into(),
                Err(StatusCode::BAD_REQUEST),
            ),
            (
                "POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n".into(),
                Ok(()),
            ),
            (
                "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".into(),
                Ok(()),
            ),
            (
                "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".into(),
                Err(StatusCode::BAD_REQUEST),
            ),
            (
                "POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n".into(),
                Err(StatusCode::BAD_REQUEST),
            ),
        ];
        for (index, (wire, expected)) in cases.into_iter().enumerate() {
            let mut headers = [httparse::EMPTY_HEADER; 128];
            let mut request = httparse::Request::new(&mut headers);
            assert!(request.parse(wire.as_bytes()).unwrap().is_complete());
            assert_eq!(
                crate::inbound::validate_head(&request),
                expected,
                "case {index}"
            );
        }
    }

    #[tokio::test]
    #[expect(clippy::unwrap_used, reason = "test socket setup and assertions")]
    async fn maximum_valid_head_fits_the_preface_budget() {
        use tokio::io::AsyncWriteExt;
        use tokio::net::{TcpListener, TcpStream};

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut sender = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut receiver, _) = listener.accept().await.unwrap();
        // Exercise a 16 KiB target, 64 KiB target-plus-field-byte total and
        // 128-field limits together, including every wire separator.
        let mut wire = format!("GET /{} HTTP/1.1\r\n", "x".repeat(16_383));
        let field = format!("X: {}\r\n", "x".repeat(383));
        for _ in 0..128 {
            wire.push_str(&field);
        }
        wire.push_str("\r\n");
        let write = tokio::spawn(async move {
            sender.write_all(wire.as_bytes()).await.unwrap();
            sender.shutdown().await.unwrap();
            wire
        });
        let received = crate::inbound::read_preface(&mut receiver).await.unwrap();
        assert_eq!(received, write.await.unwrap().as_bytes());
    }

    #[tokio::test]
    #[expect(clippy::unwrap_used, reason = "test socket setup and assertions")]
    async fn raw_head_budget_includes_optional_whitespace() {
        use tokio::io::AsyncWriteExt;
        use tokio::net::{TcpListener, TcpStream};

        for excess in [0, 1] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let mut sender = TcpStream::connect(listener.local_addr().unwrap())
                .await
                .unwrap();
            let (mut receiver, _) = listener.accept().await.unwrap();
            let prefix = "GET / HTTP/1.1\r\nX: ";
            let suffix = "x\r\n\r\n";
            let padding = " ".repeat(82_496 - prefix.len() - suffix.len() + excess);
            let wire = format!("{prefix}{padding}{suffix}");
            sender.write_all(wire.as_bytes()).await.unwrap();
            let result = crate::inbound::read_preface(&mut receiver).await;
            if excess == 0 {
                assert_eq!(result.unwrap(), wire.as_bytes());
            } else {
                assert_eq!(
                    result.unwrap_err(),
                    hyper::StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE
                );
            }
        }
    }

    #[tokio::test]
    #[expect(clippy::unwrap_used, reason = "test socket setup and assertions")]
    async fn unfinished_request_line_has_a_fixed_memory_budget() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::{TcpListener, TcpStream};

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut sender = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut receiver, _) = listener.accept().await.unwrap();
        // 64 KiB metadata + 16 KiB whitespace + separators and line overhead.
        // Keep the write side open: rejection must come from the byte budget.
        sender.write_all(&vec![b'G'; 82_496 + 4096]).await.unwrap();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            crate::inbound::read_preface(&mut receiver),
        )
        .await
        .unwrap();
        assert_eq!(
            result.unwrap_err(),
            hyper::StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE
        );
        sender.shutdown().await.unwrap();
        let mut unread = Vec::new();
        receiver.read_to_end(&mut unread).await.unwrap();
        assert_eq!(unread, vec![b'G'; 4096]);
    }

    #[tokio::test]
    #[expect(clippy::unwrap_used, reason = "test socket setup and assertions")]
    async fn refusal_writes_a_complete_empty_response() {
        use tokio::io::AsyncReadExt;
        use tokio::net::{TcpListener, TcpStream};

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut server, _) = listener.accept().await.unwrap();
        crate::inbound::refuse(&mut server, hyper::StatusCode::BAD_REQUEST).await;
        drop(server);
        let mut wire = Vec::new();
        client.read_to_end(&mut wire).await.unwrap();
        assert_eq!(
            wire,
            b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        );
    }

    #[tokio::test]
    #[expect(clippy::unwrap_used, reason = "test socket setup and assertions")]
    async fn prefetched_body_and_unread_bytes_are_replayed_exactly() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::{TcpListener, TcpStream};

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut sender = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut receiver, _) = listener.accept().await.unwrap();
        let header = b"POST /v1/messages HTTP/1.1\r\nHost: guest\r\nContent-Length: 8192\r\n\r\n";
        let mut wire = header.to_vec();
        wire.extend((0..=255_u8).cycle().take(8192));
        sender.write_all(&wire).await.unwrap();
        sender.shutdown().await.unwrap();
        let prefix = crate::inbound::read_preface(&mut receiver).await.unwrap();
        let mut replay = std::io::Cursor::new(prefix).chain(receiver);
        let mut actual = Vec::new();
        replay.read_to_end(&mut actual).await.unwrap();
        assert_eq!(actual, wire);
    }

    #[test]
    fn raw_target_is_never_normalized_before_validation() {
        for valid in ["/v1/messages", "/v1/messages?x=%2f", "/v1/messages?"] {
            assert!(valid_target(valid));
        }
        for invalid in [
            "*",
            "api.anthropic.com:443",
            "https://api.anthropic.com/v1/messages",
            "//evil/v1/messages",
            "/v1/messages#fragment",
            "/v1/messages?x=%gg",
            "/v1/messages?x=%g0",
            "/v1/messages?x=%0g",
            "/v1/messages?x=%",
            "/v1/messages?x=%0",
            "/v1/messages?x=%2f#fragment",
            "/v1/messages?x=%2f%gg",
            "/v1/messages\\x",
            "/v1/messages\r\n",
        ] {
            assert!(!valid_target(invalid), "{invalid}");
        }
    }
}
