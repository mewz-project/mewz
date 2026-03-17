# file_write

This example demonstrates file writing on Mewz using virtio-fs.

It creates a file, writes content to it, reads it back, and verifies that the content matches.

## How to run on Mewz

The following steps can be executed within the Dev Container.

First, build the program into Wasm.

```sh
cd examples/file_write
cargo build --target wasm32-wasip1
```

Then, convert it into a native object file with Wasker.

```sh
wasker target/wasm32-wasip1/debug/file_write.wasm
```

Now build and run the Mewz kernel with the Wasm application and virtio-fs.

```sh
cd ../..
mkdir -p /tmp/mewz-shared
zig build -Dapp-obj=examples/file_write/wasm.o -Dmount=/tmp/mewz-shared run
```

After execution, `output.txt` will appear in the shared directory.

> **Note:** This example requires virtio-fs because it performs file writes, which are not supported by the in-memory (read-only) filesystem.
