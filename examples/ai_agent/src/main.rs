mod agent;
mod llm;
mod tools;

use std::convert::Infallible;
use std::net::SocketAddr;

use hyper::server::conn::Http;
use hyper::service::service_fn;
use hyper::{Body, Method, Request, Response, StatusCode};
use tokio::net::TcpListener;

#[derive(serde::Deserialize)]
struct AgentRequest {
    task: String,
}

async fn handle(req: Request<Body>) -> Result<Response<Body>, Infallible> {
    match (req.method(), req.uri().path()) {
        (&Method::GET, "/") => Ok(json_response(
            StatusCode::OK,
            serde_json::json!({
                "name": "mewz-ai-agent",
                "mode": "mock-react",
                "endpoints": {
                    "GET /": "this help message",
                    "POST /agent": "run the agent with {\"task\": \"...\"}"
                },
                "examples": [
                    {"task": "2+2を計算して"},
                    {"task": "今の時刻を教えて"},
                    {"task": "今の時刻の分を2倍して"},
                    {"task": "READMEを読んで"}
                ]
            }),
        )),

        (&Method::POST, "/agent") => {
            let body = match hyper::body::to_bytes(req.into_body()).await {
                Ok(bytes) => bytes,
                Err(err) => {
                    return Ok(text_response(
                        StatusCode::BAD_REQUEST,
                        format!("failed to read body: {err}"),
                    ));
                }
            };

            let payload: AgentRequest = match serde_json::from_slice(&body) {
                Ok(value) => value,
                Err(err) => {
                    return Ok(text_response(
                        StatusCode::BAD_REQUEST,
                        format!("invalid json: {err}"),
                    ));
                }
            };

            if payload.task.trim().is_empty() {
                return Ok(text_response(
                    StatusCode::BAD_REQUEST,
                    "task must not be empty".to_string(),
                ));
            }

            let result = agent::run(payload.task.trim());
            Ok(json_response(StatusCode::OK, result))
        }

        _ => Ok(text_response(
            StatusCode::NOT_FOUND,
            "not found".to_string(),
        )),
    }
}

fn json_response<T: serde::Serialize>(status: StatusCode, value: T) -> Response<Body> {
    let body = serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_string());
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(body))
        .unwrap()
}

fn text_response(status: StatusCode, message: String) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", "text/plain; charset=utf-8")
        .body(Body::from(message))
        .unwrap()
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let addr = SocketAddr::from(([0, 0, 0, 0], 1234));
    let listener = TcpListener::bind(addr).await?;

    println!("Mewz AI Agent listening on http://{addr}");
    println!("Try: curl -X POST localhost:1234/agent -H 'content-type: application/json' -d '{{\"task\":\"2+2を計算して\"}}'");

    loop {
        let (stream, _) = listener.accept().await?;

        tokio::task::spawn(async move {
            if let Err(err) = Http::new()
                .serve_connection(stream, service_fn(handle))
                .await
            {
                println!("Error serving connection: {err:?}");
            }
        });
    }
}
