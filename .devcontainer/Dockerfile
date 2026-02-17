FROM mcr.microsoft.com/devcontainers/rust:1-1-bookworm

RUN apt-get update && apt-get install -y cmake vim gdb

ARG LLVM_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.0/clang+llvm-15.0.0-x86_64-linux-gnu-rhel-8.4.tar.xz
ARG ZIG_URL=https://ziglang.org/builds/zig-x86_64-linux-0.16.0-dev.2611+f996d2866.tar.xz

ENV PATH="/usr/bin/zig:${PATH}"
ENV PATH=/usr/local/llvm/bin:$PATH
ENV LLVM_SYS_150_PREFIX=/usr/local/llvm/clang+llvm-15.0.0-x86_64-linux-gnu-rhel-8.4

# install llvm
RUN mkdir -p /usr/local/llvm \
    && wget ${LLVM_URL} -O /tmp/llvm.tar.xz \
    && tar -xvf /tmp/llvm.tar.xz -C /usr/local/llvm \
    && rm /tmp/llvm.tar.xz

WORKDIR /work

RUN git clone https://github.com/mewz-project/wasker.git \
    && cd wasker \
    && cargo build --release \
    && cp target/release/wasker /usr/bin

RUN apt-get update && \
    apt-get install -y \
    curl \
    xz-utils \
    qemu-system \
    qemu-system-common \
    qemu-utils \
    cmake

RUN curl -SL ${ZIG_URL} \
    | tar -xJC /tmp \
    && mv /tmp/$(basename ${ZIG_URL} .tar.xz) /usr/bin/zig

RUN mkdir -p /home/vscode/.config/gdb \
    && echo "add-auto-load-safe-path /workspaces/mewz/.gdbinit" > /home/vscode/.config/gdb/gdbinit

USER vscode

WORKDIR /workspaces/mewz
