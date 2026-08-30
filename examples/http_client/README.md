# http_client

This example performs HTTP and HTTPS GET requests using domain name resolution via `sock_getaddrinfo`.

HTTPS requires Mewz to provide a wall clock (`clock_time_get` with `CLOCKID_REALTIME`) so TLS certificate validation can succeed.

## Build (Wasm)

Use release build and the required `RUSTFLAGS` (debug builds panic in `wasi_mio` on `set_nodelay`):

```sh
cd examples/http_client
RUSTFLAGS="--cfg wasmedge --cfg tokio_unstable --cfg skip_wasi_unsupported" \
  cargo build --release --target wasm32-wasip1
```

The Wasm binary is emitted under `target/wasm32-wasip1/release/deps/` (for example `http_client-*.wasm`).

Convert it to a native object file with [Wasker](https://github.com/mewz-project/wasker):

```sh
WASM=$(ls target/wasm32-wasip1/release/deps/http_client-*.wasm | head -1)
wasker "$WASM"
```

If Wasker is not installed:

```sh
curl -L -o /tmp/wasker.tar.gz \
  https://github.com/mewz-project/wasker/releases/download/v0.1.1/wasker-0.1.1-linux-x86_64-gnu.tar.gz
tar -xzf /tmp/wasker.tar.gz -C /tmp
sudo install -m 755 /tmp/wasker /usr/local/bin/wasker
```

## Run on Mewz

```sh
cd ../..
zig build -Dapp-obj=examples/http_client/wasm.o run
```

On success, serial output shows HTTP status codes (for example `Status: 200` for `https://example.com/`).

> [!NOTE]
> To quit the QEMU process, press Ctrl+A, then X.

> [!NOTE]
> External network access requires QEMU user networking. The kernel uses DNS server `10.0.2.3` by default.

> [!NOTE]
> REALTIME is derived from the QEMU CMOS/RTC at boot. If RTC is unavailable, pass a kernel cmdline option such as `epoch=1735689600` (Unix seconds).

## Dependencies

This example follows the [WasmEdge wasmedge_reqwest_demo](https://github.com/WasmEdge/wasmedge_reqwest_demo) approach:

- Git patches for `tokio`, `mio`, `socket2`, `hyper`, and `reqwest` (WASI ports)
- `reqwest` with `rustls-tls` for HTTPS

Use crates.io `reqwest` on `wasm32-wasip1` without the `wasi_reqwest` patch and it falls back to the browser `fetch` backend, which does not work on Mewz.
