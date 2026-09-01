# ai_agent

A minimal ReAct-style AI agent demo that runs on Mewz as Wasm.

The agent exposes an HTTP API, calls OpenAI's Chat Completions API, and uses simple built-in tools:

- `calculator` - evaluate basic arithmetic expressions
- `get_time` - return the current UTC time
- `read_file` - read a file from the bundled read-only filesystem
- `echo` - echo the input task

## How to run on Mewz

The following steps can be executed within the Dev Container.

First, build the program into Wasm. Use a release build and the required `RUSTFLAGS` (debug builds panic in `wasi_mio` on `set_nodelay`):

```sh
cd examples/ai_agent
RUSTFLAGS="--cfg wasmedge --cfg tokio_unstable --cfg skip_wasi_unsupported" \
  cargo build --release --target wasm32-wasip1
```

Then, convert it into a native object file with Wasker.

```sh
wasker target/wasm32-wasip1/release/ai_agent.wasm
```

Now you can run it on Mewz. Use `-Ddir` to bundle demo files for the `read_file` tool, and pass your OpenAI API key as a command-line argument:

```sh
cd ../..
zig build -Dapp-obj=examples/ai_agent/wasm.o -Ddir=examples/ai_agent/files \
  -Dargs="ai_agent --api-key $OPENAI_API_KEY" run
```

You can access the agent at `localhost:1234`.

```sh
# Help
curl localhost:1234

# Simple calculation
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"Calculate 2+2"}'

# Current time
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"What time is it now?"}'

# Multi-step task: get time, then multiply minutes by 2
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"Double the current minute"}'

# Read bundled README
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"Read the README"}'
```

> [!NOTE]
> To quit the QEMU process, press Ctrl+A, then X.

> [!NOTE]
> QEMU's port 1234 is mapped to localhost:1234. But the other ports are not mapped.
> To map another port, edit the QEMU's option.

> [!NOTE]
> HTTPS to OpenAI requires Mewz to provide a wall clock (`clock_time_get` with `CLOCKID_REALTIME`) so TLS certificate validation can succeed.

> [!NOTE]
> External network access requires QEMU user networking. The kernel uses DNS server `10.0.2.3` by default.

## API key

Pass the OpenAI API key with `--api-key`:

```sh
ai_agent --api-key sk-...
```

If `--api-key` is omitted, the agent falls back to the `OPENAI_API_KEY` environment variable. On Mewz, prefer passing the key through `-Dargs` as shown above.
