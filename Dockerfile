FROM ghcr.io/mewz-project/wasker:latest

ARG ZIG_VERSION=zig-x86_64-linux-0.16.0-dev.2611+f996d2866

ENV PATH="/usr/bin/zig:${PATH}"

WORKDIR /mewz

RUN apt-get update && \
    apt-get install -y curl xz-utils qemu-system qemu-system-common qemu-utils git cmake libstdc++6 build-essential && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN curl -SL https://ziglang.org/builds/${ZIG_VERSION}.tar.xz \
    | tar -xJC /tmp \
    && mv /tmp/${ZIG_VERSION} /usr/bin/zig

COPY . .

RUN ./scripts/build-newlib.sh && ./scripts/build-lwip.sh

ENTRYPOINT [ "./scripts/run.sh" ]
