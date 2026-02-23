use std::fs;
use std::io::Write;

fn main() {
    println!("=== Mewz file_write example ===");

    let path = "output.txt";
    let content = "Hello from Mewz!\n";

    println!("Writing to {}", path);
    let mut file = fs::File::create(path).expect("failed to create file");
    file.write_all(content.as_bytes())
        .expect("failed to write");
    drop(file);

    println!("Reading back from {}", path);
    let read_back = fs::read_to_string(path).expect("failed to read file");
    assert_eq!(read_back, content, "content mismatch");

    println!("Content verified: {}", read_back.trim());
    println!("=== file_write example finished successfully ===");
}
