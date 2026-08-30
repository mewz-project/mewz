async fn fetch(url: &str) -> Result<(), reqwest::Error> {
    println!("GET {url}...");
    let response = reqwest::get(url).await?;
    println!("Status: {}", response.status());
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), reqwest::Error> {
    fetch("https://example.com/").await?;
    fetch("http://google.com/").await?;
    Ok(())
}
