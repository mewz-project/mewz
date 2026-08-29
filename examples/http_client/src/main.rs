use hyper::{Body, Client, Uri};
use hyper_rustls::HttpsConnectorBuilder;
use rustls::RootCertStore;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

fn build_https_client() -> Result<Client<hyper_rustls::HttpsConnector<hyper::client::HttpConnector>>, BoxError> {
    let mut root_store = RootCertStore::empty();
    root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

    let tls = rustls::ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();

    let https = HttpsConnectorBuilder::new()
        .with_tls_config(tls)
        .https_or_http()
        .enable_http1()
        .build();

    Ok(Client::builder().build::<_, Body>(https))
}

async fn fetch(url: &str) -> Result<(), BoxError> {
    println!("GET {url}...");

    let uri: Uri = url.parse()?;
    let client = build_https_client()?;
    let response = client.get(uri).await?;

    println!("Status: {}", response.status());

    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), BoxError> {
    fetch("https://example.com/").await?;
    fetch("http://google.com/").await?;
    Ok(())
}
