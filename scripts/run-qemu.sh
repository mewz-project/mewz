#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

QEMU_BIN="qemu-system-x86_64"
QEMU_ARGS=(
    "-kernel"
    "zig-out/bin/mewz.qemu.elf"
    "-cpu"
    "Icelake-Server"
    "-m"
    "512"
    "-device"
    "virtio-net,netdev=net0,disable-legacy=on,disable-modern=off"
    "-netdev"
    "user,id=net0,hostfwd=tcp:0.0.0.0:1234-:1234"
    "-no-reboot"
    "-serial"
    "mon:stdio"
    "-monitor"
    "telnet::3333,server,nowait"
    "-nographic"
    "-gdb"
    "tcp::12345"
    "-object"
    "filter-dump,id=fiter0,netdev=net0,file=virtio-net.pcap"
    "-device"
    "isa-debug-exit,iobase=0x501,iosize=2"
    "-append"
    "ip=10.0.2.15/24 gateway=10.0.2.2"
)

DEBUG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -d | --debug)
            DEBUG=true
            ;;
        --vaccel)
            QEMU_ARGS+=("-object" "acceldev-backend-vaccel,id=gen0"
                         "-device" "virtio-accel-pci,id=accl0,runtime=gen0")
            # TODO: Add qemu-vaccel as a dependency
            QEMU_BIN="/opt/mount/qemu-vaccel/build/qemu-system-x86_64"
            ;;
        -*)
            echo "invalid option"
            exit 1
            ;;
        *)
            ;;
    esac
    shift
done

if $DEBUG; then
    QEMU_ARGS+=("-S")
fi

# Let x be the return code of Mewz. Then, the return code of QEMU is 2x+1.
"$QEMU_BIN" "${QEMU_ARGS[@]}" || QEMU_RETURN_CODE=$(( $? ))
RETURN_CODE=$(( (QEMU_RETURN_CODE-1)/2 ))

exit $RETURN_CODE

