FROM mcr.microsoft.com/devcontainers/rust:1-1-bookworm

RUN apt-get update && apt-get install -y cmake

ARG LLVM_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.0/clang+llvm-15.0.0-x86_64-linux-gnu-rhel-8.4.tar.xz
ARG ZIG_VERSION=zig-linux-x86_64-0.12.0-dev.1856+94c63f31f

ENV PATH="/usr/bin/zig:${PATH}"
ENV PATH=/usr/local/llvm/bin:$PATH
ENV LLVM_SYS_150_PREFIX=/usr/local/llvm/clang+llvm-15.0.0-x86_64-linux-gnu-rhel-8.4

# install llvm
RUN mkdir -p /usr/local/llvm \
    && wget ${LLVM_URL} -O /tmp/llvm.tar.xz \
    && tar -xvf /tmp/llvm.tar.xz -C /usr/local/llvm \
    && rm /tmp/llvm.tar.xz

WORKDIR /work

RUN git clone https://github.com/Mewz-project/Wasker.git \
    && cd Wasker \
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

RUN curl -SL https://ziglang.org/builds/${ZIG_VERSION}.tar.xz \
    | tar -xJC /tmp \
    && mv /tmp/${ZIG_VERSION} /usr/bin/zig
