#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

if $# -ne 1; then
    echo "Usage: run.sh <path to Wasm file>"
    exit 1
fi

WASM_FILE=$1

wasker /volume/$WASM_FILE

zig build -Dapp-obj=wasm.o -Doptimize=ReleaseSmall run
