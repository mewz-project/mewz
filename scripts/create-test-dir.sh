#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

mkdir -p build/test
echo "fd_read test" > build/test/test.txt
