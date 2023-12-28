#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

mkdir -p build/lwip
cd build/lwip
cmake ../../lwip-wrapper
cmake --build .
