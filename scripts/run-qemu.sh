#!/bin/bash
set -ex

REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT

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
VIRTIOFS_DIR=""

find_virtiofsd() {
    if command -v virtiofsd >/dev/null 2>&1; then
        command -v virtiofsd
        return 0
    fi

    local candidate
    for candidate in \
        /usr/libexec/virtiofsd \
        /usr/lib/qemu/virtiofsd \
        /usr/lib/virtiofsd \
        /usr/local/libexec/virtiofsd; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -d | --debug)
            DEBUG=true
            ;;
        --virtiofs)
            shift
            if [[ $# -eq 0 || "$1" == -* ]]; then
                echo "missing argument for --virtiofs: expected directory path" >&2
                exit 1
            fi
            VIRTIOFS_DIR="$1"
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

if [[ -n "$VIRTIOFS_DIR" ]]; then
    VIRTIOFS_SOCK="/tmp/mewz-virtiofsd-$$"
    if ! VIRTIOFSD="$(find_virtiofsd)"; then
        echo "virtiofsd was not found. Install it and ensure it is in PATH or one of: /usr/libexec/virtiofsd, /usr/lib/qemu/virtiofsd, /usr/lib/virtiofsd, /usr/local/libexec/virtiofsd"
        exit 1
    fi

    VIRTIOFS_DIR_ABS="$(cd "$VIRTIOFS_DIR" && pwd)"
    sudo "$VIRTIOFSD" --socket-path="$VIRTIOFS_SOCK" -o source="$VIRTIOFS_DIR_ABS" -o sandbox=chroot >/dev/null 2>&1 &
    VIRTIOFSD_PID=$!
    trap "sudo kill $VIRTIOFSD_PID 2>/dev/null; sudo rm -f $VIRTIOFS_SOCK" EXIT

    # Wait for socket to appear
    for i in $(seq 1 20); do
        [[ -S "$VIRTIOFS_SOCK" ]] && break
        sleep 0.2
    done
    if [[ ! -S "$VIRTIOFS_SOCK" ]]; then
        echo "virtiofsd socket did not appear"
        exit 1
    fi
    sudo chmod 666 "$VIRTIOFS_SOCK"

    QEMU_ARGS+=(
        "-chardev" "socket,id=char0,path=$VIRTIOFS_SOCK"
        "-device" "vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=myfs"
        "-object" "memory-backend-memfd,id=mem,size=512M,share=on"
        "-machine" "memory-backend=mem"
    )
fi

if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ARGS+=("-accel" "kvm")
fi

# Let x be the return code of Mewz. Then, the return code of QEMU is 2x+1.
qemu-system-x86_64 "${QEMU_ARGS[@]}" || QEMU_RETURN_CODE=$(( $? ))
RETURN_CODE=$(( (QEMU_RETURN_CODE-1)/2 ))

exit $RETURN_CODE
