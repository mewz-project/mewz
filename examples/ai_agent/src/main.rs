mod agent;
mod llm;
mod tools;

use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;

use hyper::server::conn::Http;
use hyper::service::service_fn;
use hyper::{Body, Method, Request, Response, StatusCode};
use tokio::net::TcpListener;

#[derive(serde::Deserialize)]
struct AgentRequest {
    task: String,
}

fn parse_api_key() -> Result<String, String> {
    let mut args = std::env::args().skip(1).peekable();

    while let Some(arg) = args.next() {
        if arg == "--api-key" {
            return args
                .next()
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| "--api-key requires a non-empty value".to_string());
        }

        if let Some(value) = arg.strip_prefix("--api-key=") {
            if value.trim().is_empty() {
                return Err("--api-key requires a non-empty value".to_string());
            }
            return Ok(value.to_string());
        }

        if arg == "--help" || arg == "-h" {
            print_usage();
            std::process::exit(0);
        }
    }

    std::env::var("OPENAI_API_KEY").map_err(|_| {
        "missing OpenAI API key: pass --api-key or set OPENAI_API_KEY".to_string()
    })
}

fn print_usage() {
    println!(
        "Usage: ai_agent --api-key <KEY>\n\
         \n\
         Options:\n\
           --api-key <KEY>   OpenAI API key (required unless OPENAI_API_KEY is set)\n\
           --help, -h        Show this help message"
    );
}

async fn handle(api_key: Arc<String>, req: Request<Body>) -> Result<Response<Body>, Infallible> {
    match (req.method(), req.uri().path()) {
        (&Method::GET, "/") => Ok(json_response(
            StatusCode::OK,
            serde_json::json!({
                "name": "mewz-ai-agent",
                "mode": "openai-react",
                "endpoints": {
                    "GET /": "this help message",
                    "POST /agent": "run the agent with {\"task\": \"...\"}"
                },
                "examples": [
                    {"task": "Calculate 2+2"},
                    {"task": "What time is it now?"},
                    {"task": "Double the current minute"},
                    {"task": "Read the README"}
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

            match agent::run(&api_key, payload.task.trim()).await {
                Ok(result) => Ok(json_response(StatusCode::OK, result)),
                Err(err) => Ok(json_response(
                    StatusCode::BAD_GATEWAY,
                    serde_json::json!({
                        "error": err,
                    }),
                )),
            }
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
    let api_key = Arc::new(parse_api_key()?);
    let addr = SocketAddr::from(([0, 0, 0, 0], 1234));
    let listener = TcpListener::bind(addr).await?;

    println!("Mewz AI Agent listening on http://{addr}");
    println!("Try: curl -X POST localhost:1234/agent -H 'content-type: application/json' -d '{{\"task\":\"Calculate 2+2\"}}'");

    loop {
        let (stream, _) = listener.accept().await?;
        let api_key = Arc::clone(&api_key);

        tokio::task::spawn(async move {
            if let Err(err) = Http::new()
                .serve_connection(
                    stream,
                    service_fn(move |req| {
                        let api_key = Arc::clone(&api_key);
                        handle(api_key, req)
                    }),
                )
                .await
            {
                println!("Error serving connection: {err:?}");
            }
        });
    }
}
