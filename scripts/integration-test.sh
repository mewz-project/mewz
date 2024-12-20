#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

mkdir -p build/test
(stty -echo; sleep 4; (sleep 0.5; echo q) | telnet localhost 1234) &
(sleep 2; curl localhost:1234) &
./scripts/run-qemu.sh "$@" | tee build/test/output.txt

if ! grep -q "Integration test passed" build/test/output.txt; then
  echo "Integration Test FAILED!!"
  echo "output:"
  cat build/test/output.txt
  exit 1
fi

echo -e "\nIntegration Test PASSED!!"
