#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

if ls build/newlib/libc.a ; then
    echo "newlib already built"
else
    mkdir -p build/newlib
    cd build/newlib
    ../../submodules/newlib/newlib/configure --target=x86_64-elf --disable-multilib --prefix=/usr/local/newlib-x86_64-elf
    make
fi
