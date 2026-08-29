# http_client

This example performs an HTTP GET request to `google.com` using domain name resolution via `sock_getaddrinfo`.

## How to run on Mewz

The following steps can be executed within the Dev Container.

First, build the program into Wasm.

```sh
cd examples/http_client
cargo build --target wasm32-wasip1
```

Then, convert it into a native object file with Wasker.

```sh
wasker target/wasm32-wasip1/debug/http_client.wasm
```

Now you can run it on Mewz.

```sh
cd ../..
zig build -Dapp-obj=examples/http_client/wasm.o run
```

On success, the serial output shows an HTTP response from Google (for example `HTTP/1.1 301` or `HTTP/1.1 200`).

> [!NOTE]
> To quit the QEMU process, press Ctrl+A, then X.

> [!NOTE]
> External network access requires QEMU user networking. The kernel uses DNS server `10.0.2.3` by default.
