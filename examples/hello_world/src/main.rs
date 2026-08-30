fn main() {
    let names: Vec<String> = std::env::args().skip(1).collect();

    if names.is_empty() {
        println!("Hello, world!");
    } else {
        for name in names {
            println!("Hello, {name}!");
        }
    }
}
