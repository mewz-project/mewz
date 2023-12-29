# http_server

This is a simple HTTP server program.

## How to run on Mewz

The following steps can be executed within the Dev Container.

First, build the program into Wasm.

```sh
cd examples/http_server
cargo build --target wasm32-wasi
```

Then, convert it into a native object file with Wasker.

```sh
wasker target/wasm32-wasi/debug/http_server.wasm
```

Now you can run it on Mewz.

```sh
cd ../..
zig build -Dapp-obj=examples/http_server/wasm.o run
```

You can access the server at `localhost:1234`.

```
# In another terminal
curl localhost:1234
```

> [!NOTE]
> To quit the QEMU process, press Ctrl+A, then X.

> [!NOTE]
> QEMU's port 1234 is mapped to localhost:1234. But the other ports are not mapped.
> To map another port, edit the QEMU's option.
