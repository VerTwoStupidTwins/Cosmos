//! Just enough HTTP to read JSON from llama-swap and the memory service, both on this machine.
//!
//! Requests are HTTP/1.0, so the server closes the connection after one response and never chunks it.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpStream, UnixStream};

const TIMEOUT: Duration = Duration::from_secs(10);

/// GET a JSON document from a plain `http://host:port/path` URL.
pub async fn get_json(url: &str) -> Result<Value> {
    let rest = url.strip_prefix("http://").context("only http:// URLs are supported")?;
    let (host, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    tokio::time::timeout(TIMEOUT, async {
        let stream = TcpStream::connect(host).await.with_context(|| format!("connecting to {host}"))?;
        request(stream, host, path).await
    })
    .await
    .context("timed out")?
}

/// GET a JSON document from a server on a Unix socket.
pub async fn get_json_unix(socket: &str, path: &str) -> Result<Value> {
    tokio::time::timeout(TIMEOUT, async {
        let stream = UnixStream::connect(socket).await.with_context(|| format!("connecting to {socket}"))?;
        request(stream, "localhost", path).await
    })
    .await
    .context("timed out")?
}

async fn request<S: AsyncRead + AsyncWrite + Unpin>(mut stream: S, host: &str, path: &str) -> Result<Value> {
    stream
        .write_all(format!("GET {path} HTTP/1.0\r\nHost: {host}\r\nAccept: application/json\r\n\r\n").as_bytes())
        .await?;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await?;
    parse_response(&raw)
}

fn parse_response(raw: &[u8]) -> Result<Value> {
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").context("malformed HTTP response")?;
    let head = String::from_utf8_lossy(&raw[..split]);
    let status = head.lines().next().unwrap_or_default();
    let code = status.split_whitespace().nth(1).unwrap_or_default();
    if !code.starts_with('2') {
        bail!("HTTP Error {}", status.split_whitespace().skip(1).collect::<Vec<_>>().join(" "));
    }
    serde_json::from_slice(&raw[split + 4..]).context("response isn't JSON")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_json_body() {
        let raw = b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"running\":[]}";
        assert_eq!(parse_response(raw).unwrap(), serde_json::json!({"running": []}));
    }

    #[test]
    fn reports_an_error_status() {
        let raw = b"HTTP/1.0 503 Service Unavailable\r\n\r\nbusy";
        assert_eq!(parse_response(raw).unwrap_err().to_string(), "HTTP Error 503 Service Unavailable");
    }
}
