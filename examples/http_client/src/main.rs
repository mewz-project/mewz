use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    println!("Connecting to google.com:80...");

    let mut stream = TcpStream::connect("google.com:80").await?;
    stream
        .write_all(b"GET / HTTP/1.1\r\nHost: google.com\r\nConnection: close\r\n\r\n")
        .await?;

    let mut buf = [0u8; 1024];
    let n = stream.read(&mut buf).await?;
    let response = String::from_utf8_lossy(&buf[..n]);
    println!("Response:\n{}", response);

    Ok(())
}
