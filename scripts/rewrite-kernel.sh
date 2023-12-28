#!/bin/bash
set -eux

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

file_path="zig-out/bin/mewz.elf"
offset=18
new_data="\x03\x00"
data_size=2

head -c $offset "$file_path" > temp_head
tail -c +$((offset + 1 + data_size)) "$file_path" > temp_tail

cat temp_head <(echo -n -e "$new_data") temp_tail > "$file_path"

rm temp_head temp_tail
