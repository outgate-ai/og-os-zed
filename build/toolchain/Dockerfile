# Copyright (C) 2026 Outgate. Licensed under the Apache License, Version 2.0.
#
# The og-zed-toolchain image: Rust and the Android NDK on a digest-pinned Ubuntu, with packages from a dated Ubuntu
# snapshot. build/zed.sh builds it with BASE_IMAGE and APT_SNAPSHOT from pins, in a context directory that holds the
# sha256-checked Rust tarballs (+ .sha256), the NDK zip and Google's sha1 for it (ndk.sha1.google).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG APT_SNAPSHOT

USER root
# build-essential: the host linker for build scripts and proc-macros; ca-certificates: `cargo fetch` over https;
# unzip and xz-utils: unpacking the NDK and Rust below.
RUN set -eu; \
    apt-get update --snapshot "$APT_SNAPSHOT"; \
    apt-get install -y --no-install-recommends --snapshot "$APT_SNAPSHOT" \
        build-essential ca-certificates unzip xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    useradd -m builder

WORKDIR /opt/fetch
COPY rust-1.94.1-x86_64-unknown-linux-gnu.tar.xz rust-1.94.1-x86_64-unknown-linux-gnu.tar.xz.sha256 \
     rust-std-1.94.1-x86_64-linux-android.tar.xz rust-std-1.94.1-x86_64-linux-android.tar.xz.sha256 \
     rust-std-1.94.1-aarch64-linux-android.tar.xz rust-std-1.94.1-aarch64-linux-android.tar.xz.sha256 \
     android-ndk-r30-linux.zip ndk.sha1.google ./

RUN set -eu; \
    sha256sum -c rust-1.94.1-x86_64-unknown-linux-gnu.tar.xz.sha256 \
                 rust-std-1.94.1-x86_64-linux-android.tar.xz.sha256 \
                 rust-std-1.94.1-aarch64-linux-android.tar.xz.sha256; \
    echo "$(grep -oE '[0-9a-f]{40}' ndk.sha1.google | head -1)  android-ndk-r30-linux.zip" | sha1sum -c -; \
    tar -xJf rust-1.94.1-x86_64-unknown-linux-gnu.tar.xz; \
    ./rust-1.94.1-x86_64-unknown-linux-gnu/install.sh --prefix=/opt/rust --disable-ldconfig --without=rust-docs; \
    for t in rust-std-1.94.1-x86_64-linux-android rust-std-1.94.1-aarch64-linux-android; do \
        tar -xJf "$t.tar.xz"; \
        "./$t/install.sh" --prefix=/opt/rust --disable-ldconfig; \
    done; \
    unzip -q android-ndk-r30-linux.zip -d /opt; \
    mv /opt/android-ndk-r30 /opt/ndk; \
    install -d -o builder -g builder /cargo-home /target; \
    cd /; rm -rf /opt/fetch

ENV PATH=/opt/rust/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    ANDROID_NDK_HOME=/opt/ndk \
    CARGO_HOME=/cargo-home \
    CARGO_NET_OFFLINE=true

USER builder
WORKDIR /src
