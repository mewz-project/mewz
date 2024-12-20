#!/bin/bash
set -eux

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

src_path="zig-out/bin/mewz.elf"
dest_path="zig-out/bin/mewz.qemu.elf"
offset=18
new_data="\x03\x00"
data_size=2

cp "$src_path" "$dest_path"

head -c $offset "$dest_path" > temp_head
tail -c +$((offset + 1 + data_size)) "$dest_path" > temp_tail

cat temp_head <(echo -n -e "$new_data") temp_tail > "$dest_path"

rm temp_head temp_tail
