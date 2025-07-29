#!/bin/bash
set -ex

# Parse command line arguments to check for --ci option
CI_MODE=false
RUN_QEMU_ARGS=()

for arg in "$@"; do
  if [ "$arg" = "--ci" ]; then
    CI_MODE=true
  else
    RUN_QEMU_ARGS+=("$arg")
  fi
done

# Set sleep times based on CI mode
if [ "$CI_MODE" = true ]; then
  TELNET_SLEEP=10
  TELNET_ECHO_SLEEP=2
  CURL_SLEEP=8
else
  TELNET_SLEEP=4
  TELNET_ECHO_SLEEP=0.5
  CURL_SLEEP=2
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

mkdir -p build/test
(stty -echo; sleep $TELNET_SLEEP; (sleep $TELNET_ECHO_SLEEP; echo q) | telnet localhost 1234) &
(sleep $CURL_SLEEP; curl localhost:1234) &
./scripts/run-qemu.sh "${RUN_QEMU_ARGS[@]}" | tee build/test/output.txt

if ! grep -q "Integration test passed" build/test/output.txt; then
  echo "Integration Test FAILED!!"
  echo "output:"
  cat build/test/output.txt
  exit 1
fi

echo -e "\nIntegration Test PASSED!!"
