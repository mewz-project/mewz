#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

with_timeout() {

    time=$1

    # start the command in a subshell to avoid problem with pipes
    # (spawn accepts one command)
    command="/bin/sh -c \"$2\""

    expect -c "set echo \"-noecho\"; set timeout $time; spawn -noecho $command; expect timeout { exit 1 } eof { exit 0 }"

}

mkdir -p build/test
(sleep 2; curl localhost:1234) &
with_timeout 5 ./scripts/run-qemu.sh > build/test/output.txt

if ! grep -q "Integration test passed" build/test/output.txt; then
  echo "Integration Test FAILED!!"
  echo "output:"
  cat build/test/output.txt
  exit 1
fi

echo -e "\nIntegration Test PASSED!!"
