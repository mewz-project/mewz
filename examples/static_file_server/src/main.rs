use std::fs;
use warp::http::Response;

use warp::Filter;

fn response(path: String) -> Response<Vec<u8>> {
    match fs::read(path) {
        Ok(content) => Response::builder().body(content).unwrap(),
        Err(e) => match e.kind() {
            std::io::ErrorKind::NotFound => Response::builder()
                .status(warp::http::StatusCode::NOT_FOUND)
                .body("Not Found".into())
                .unwrap(),
            _ => {
                eprintln!("Error: {}", e);
                Response::builder()
                    .status(warp::http::StatusCode::INTERNAL_SERVER_ERROR)
                    .body("Internal Server Error".into())
                    .unwrap()
            }
        },
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    // GET /
    let index = warp::get()
        .and(warp::path::end())
        .map(|| response("index.html".to_string()));

    let static_files = warp::path!(String).map(|path: String| response(path));

    let routes = index.or(index).or(static_files);
    warp::serve(routes).run(([0, 0, 0, 0], 1234)).await
}
