# hello_world

This is a simple Hello World program.

## How to run on Mewz

The following steps can be executed within the Dev Container.

First, build the program into Wasm.

```sh
cd examples/hello_world
# In the Dev Container, you should run `rustup target add wasm32-wasi in advance.
cargo build --target wasm32-wasi
```

Then, convert it into a native object file with Wasker.

```sh
wasker target/wasm32-wasi/debug/hello_world.wasm
```

Now you can run it on Mewz.

```sh
cd ../..
zig build -Dapp-obj=examples/hello_world/wasm.o run
```
