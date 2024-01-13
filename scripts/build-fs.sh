#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

# check if argument is given
if [ $# -ne 1 ]; then
    echo "Directory path is not given."
    exit 1
fi

dir_path=$1
echo "dir_path: $dir_path"

# check if directory exists
if [ ! -d $dir_path ]; then
    echo "Directory does not exist."
    exit 1
fi

# archive the directory with ustar format
# note: the root path of the archive must be `.`
mkdir -p build
tar -cf build/disk.tar --format=ustar -C $dir_path .
echo "tar archive created"

# check if llvm-objcopy is installed
if ! command -v llvm-objcopy &> /dev/null
then
    echo "llvm-objcopy could not be found"
    exit 1
fi

# convert the archive to binary
llvm-objcopy -Ibinary -Oelf64-x86-64 build/disk.tar build/disk.o
echo "disk.o created"
