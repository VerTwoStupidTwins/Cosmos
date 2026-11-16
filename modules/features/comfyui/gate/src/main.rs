//! Lets Krita use lugh's ComfyUI while llama-swap shares its card with the helper model.
//!
//! Everything passes straight through to ComfyUI, WebSockets included, except new jobs. Those go through
//! llama-swap to its `image` model, the adapter, which first makes llama-swap stop the helper. The adapter
//! queues the job, answers with ComfyUI's reply on its first line, and keeps the response open until the job
//! ends, so llama-swap won't load the helper mid-job. The gate hands the reply to Krita at once and keeps
//! reading in the background.

use std::{convert::Infallible, net::SocketAddr, sync::Arc};

use bytes::{Bytes, BytesMut};
use http_body_util::{BodyExt, Full, combinators::BoxBody};
use hyper::{
    Request, Response, StatusCode,
    body::Incoming,
    header::{self, HeaderValue},
    server::conn::http1,
    service::service_fn,
};
use hyper_util::{
    client::legacy::{Client, connect::HttpConnector},
    rt::{TokioExecutor, TokioIo},
};
use tokio::net::TcpListener;

type Body = BoxBody<Bytes, hyper::Error>;

struct Gate {
    comfyui: String,
    submit: String,
    client: Client<HttpConnector, Body>,
}

fn full(status: StatusCode, content_type: &str, data: impl Into<Bytes>) -> Response<Body> {
    let mut response = Response::new(Full::new(data.into()).map_err(|never| match never {}).boxed());
    *response.status_mut() = status;
    response.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_str(content_type).unwrap());
    response
}

fn error(status: StatusCode, message: &str) -> Response<Body> {
    let body = format!("{{\"error\":{{\"message\":{message:?}}}}}");
    full(status, "application/json", body)
}

/// Headers that belong to one connection and mustn't be passed on, unless the request is a WebSocket upgrade.
fn strip_hop_headers(headers: &mut hyper::HeaderMap, upgrading: bool) {
    for name in ["keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding"] {
        headers.remove(name);
    }
    if !upgrading {
        headers.remove(header::CONNECTION);
        headers.remove(header::UPGRADE);
    }
}

fn is_upgrade<B>(request: &Request<B>) -> bool {
    request.headers().get(header::UPGRADE).is_some()
}

impl Gate {
    async fn handle(self: Arc<Self>, request: Request<Incoming>) -> Result<Response<Body>, Infallible> {
        let path = request.uri().path();
        let response = if request.method() == hyper::Method::POST && (path == "/prompt" || path == "/api/prompt") {
            self.submit(request).await
        } else if is_upgrade(&request) {
            self.tunnel(request).await
        } else {
            self.forward(request).await
        };
        Ok(response)
    }

    fn target(&self, request: &Request<Incoming>) -> String {
        let path = request.uri().path_and_query().map_or("/", |p| p.as_str());
        format!("{}{path}", self.comfyui)
    }

    async fn forward(&self, request: Request<Incoming>) -> Response<Body> {
        let target = self.target(&request);
        let (mut parts, body) = request.into_parts();
        parts.uri = match target.parse() {
            Ok(uri) => uri,
            Err(_) => return error(StatusCode::BAD_REQUEST, "bad path"),
        };
        strip_hop_headers(&mut parts.headers, false);
        match self.client.request(Request::from_parts(parts, body.boxed())).await {
            Ok(response) => {
                let (mut parts, body) = response.into_parts();
                strip_hop_headers(&mut parts.headers, false);
                Response::from_parts(parts, body.boxed())
            }
            Err(e) => error(StatusCode::BAD_GATEWAY, &format!("ComfyUI isn't answering: {e}")),
        }
    }

    /// Krita's progress updates come over a WebSocket, which is joined to ComfyUI's end to end.
    async fn tunnel(&self, mut request: Request<Incoming>) -> Response<Body> {
        let target = self.target(&request);
        let from_client = hyper::upgrade::on(&mut request);
        let (mut parts, _) = request.into_parts();
        parts.uri = match target.parse() {
            Ok(uri) => uri,
            Err(_) => return error(StatusCode::BAD_REQUEST, "bad path"),
        };
        strip_hop_headers(&mut parts.headers, true);
        let empty = Full::new(Bytes::new()).map_err(|never| match never {}).boxed();
        let mut response = match self.client.request(Request::from_parts(parts, empty)).await {
            Ok(response) => response,
            Err(e) => return error(StatusCode::BAD_GATEWAY, &format!("ComfyUI isn't answering: {e}")),
        };
        if response.status() != StatusCode::SWITCHING_PROTOCOLS {
            let (parts, body) = response.into_parts();
            return Response::from_parts(parts, body.boxed());
        }
        let from_comfyui = hyper::upgrade::on(&mut response);
        tokio::spawn(async move {
            let (Ok(client), Ok(comfyui)) = (from_client.await, from_comfyui.await) else {
                return;
            };
            let _ = tokio::io::copy_bidirectional(&mut TokioIo::new(client), &mut TokioIo::new(comfyui)).await;
        });
        let (parts, _) = response.into_parts();
        Response::from_parts(parts, Full::new(Bytes::new()).map_err(|never| match never {}).boxed())
    }

    async fn submit(&self, request: Request<Incoming>) -> Response<Body> {
        let body = match request.into_body().collect().await {
            Ok(body) => body.to_bytes(),
            Err(_) => return error(StatusCode::BAD_REQUEST, "couldn't read the job"),
        };
        let held = Request::post(&self.submit)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Full::new(body).map_err(|never| match never {}).boxed())
            .unwrap();
        // Waits while llama-swap stops the helper and starts the adapter, and for any helper requests running.
        let response = match self.client.request(held).await {
            Ok(response) => response,
            Err(e) => return error(StatusCode::BAD_GATEWAY, &format!("llama-swap isn't answering: {e}")),
        };
        let status = response.status();
        let mut body = response.into_body();
        if status != StatusCode::OK {
            // ComfyUI rejected the job, or the adapter failed to start. The whole reply goes to Krita.
            return match body.collect().await {
                Ok(data) => full(status, "application/json", data.to_bytes()),
                Err(_) => error(status, "the job was refused"),
            };
        }
        let mut reply = BytesMut::new();
        while !reply.contains(&b'\n') {
            match body.frame().await {
                Some(Ok(frame)) => {
                    if let Ok(data) = frame.into_data() {
                        reply.extend_from_slice(&data);
                    }
                }
                _ => break,
            }
        }
        let end = reply.iter().position(|&b| b == b'\n').unwrap_or(reply.len());
        let reply = reply.split_to(end).freeze();
        if reply.is_empty() {
            return error(StatusCode::BAD_GATEWAY, "the adapter didn't pass on ComfyUI's reply");
        }
        // Holds the card for the job until the adapter ends the response.
        tokio::spawn(async move { while let Some(Ok(_)) = body.frame().await {} });
        full(StatusCode::OK, "application/json", reply)
    }
}

fn arg(name: &str) -> String {
    let args: Vec<String> = std::env::args().collect();
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
        .unwrap_or_else(|| {
            eprintln!("usage: comfyui-gate --listen ADDR:PORT --comfyui URL --submit URL");
            std::process::exit(2)
        })
}

#[tokio::main]
async fn main() {
    let listen: SocketAddr = arg("--listen").parse().expect("--listen must look like 0.0.0.0:8189");
    let mut connector = HttpConnector::new();
    connector.set_nodelay(true);
    let gate = Arc::new(Gate {
        comfyui: arg("--comfyui").trim_end_matches('/').to_string(),
        submit: arg("--submit"),
        client: Client::builder(TokioExecutor::new()).build(connector),
    });
    let listener = TcpListener::bind(listen).await.expect("couldn't listen");
    eprintln!("passing {listen} to {}", gate.comfyui);
    loop {
        let (stream, _) = tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok(accepted) => accepted,
                Err(_) => continue,
            },
            _ = tokio::signal::ctrl_c() => return,
        };
        let gate = gate.clone();
        tokio::spawn(async move {
            let service = service_fn(move |request| gate.clone().handle(request));
            let _ = http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .with_upgrades()
                .await;
        });
    }
}
