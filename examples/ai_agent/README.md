# ai_agent

A minimal ReAct-style AI agent demo that runs on Mewz as Wasm.

The agent exposes an HTTP API and uses simple built-in tools:

- `calculator` - evaluate basic arithmetic expressions
- `get_time` - return the current UTC time
- `read_file` - read a file from the bundled read-only filesystem
- `echo` - echo the input task

The "LLM" is a small rule-based planner so the demo works offline without API keys.

## How to run on Mewz

The following steps can be executed within the Dev Container.

First, build the program into Wasm.

```sh
cd examples/ai_agent
cargo build --target wasm32-wasip1
```

Then, convert it into a native object file with Wasker.

```sh
wasker target/wasm32-wasip1/debug/ai_agent.wasm
```

Now you can run it on Mewz. Use `-Ddir` to bundle demo files for the `read_file` tool.

```sh
cd ../..
zig build -Dapp-obj=examples/ai_agent/wasm.o -Ddir=examples/ai_agent/files run
```

You can access the agent at `localhost:1234`.

```sh
# Help
curl localhost:1234

# Simple calculation
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"2+2を計算して"}'

# Current time
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"今の時刻を教えて"}'

# Multi-step task: get time, then multiply minutes by 2
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"今の時刻の分を2倍して"}'

# Read bundled README
curl -X POST localhost:1234/agent \
  -H 'content-type: application/json' \
  -d '{"task":"READMEを読んで"}'
```

> [!NOTE]
> To quit the QEMU process, press Ctrl+A, then X.

> [!NOTE]
> QEMU's port 1234 is mapped to localhost:1234. But the other ports are not mapped.
> To map another port, edit the QEMU's option.
