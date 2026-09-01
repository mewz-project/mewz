use hyper::body::HttpBody;
use hyper::{Client, Uri};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let url = "http://google.com/";
    println!("GET {url}...");

    let uri: Uri = url.parse()?;
    let client = Client::new();
    let mut response = client.get(uri).await?;

    println!("Status: {}", response.status());
    println!("Headers:\n{:#?}", response.headers());

    let mut body = Vec::new();
    while let Some(chunk) = response.data().await {
        body.extend_from_slice(&chunk?);
    }

    let preview = String::from_utf8_lossy(&body);
    let lines: Vec<&str> = preview.lines().take(10).collect();
    println!("Body (first 10 lines):\n{}", lines.join("\n"));

    Ok(())
}
