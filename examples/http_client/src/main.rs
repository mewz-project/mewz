type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn fetch(client: &reqwest::Client, url: &str) -> Result<(), BoxError> {
    println!("GET {url}...");
    let response = client.get(url).send().await?;
    println!("Status: {}", response.status());
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), BoxError> {
    let client = reqwest::Client::builder().build()?;
    fetch(&client, "https://example.com/").await?;
    fetch(&client, "http://google.com/").await?;
    Ok(())
}
