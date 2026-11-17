#!/usr/bin/env bash
# Copyright (C) 2026 Outgate. Licensed under the Apache License, Version 2.0.
#
# Builds libzed_og.so, the Zed editor for OG OS (the Zed (preview) app), from source. No build output is kept in git.
#   upstream  the Zed tag tarball (sha256 pinned in pins; its extracted tree must also hash to the tag's git tree)
#   patches   ../patches/*.patch, applied with git am
#   crates    a networked `cargo fetch --locked` (each .crate is checked against its Cargo.lock checksum, git
#             dependencies are pinned by commit); skipped when the cargo home already holds everything
#   build     cargo in a sandbox: docker --network none, read-only source, read-only cargo home, no capabilities,
#             the og-zed-toolchain image (toolchain/Dockerfile; base image, packages, Rust and NDK pinned in pins)
# The result is cached under $OG_ZED_CACHE, keyed by `zed.sh --key <abi>`: unchanged inputs never rebuild.
# Needs a Linux x86_64 host with docker, curl and git. Takes no lock: callers that share a host serialize builds.
#
#   zed.sh <x86_64|arm64> [OUT_DIR]   build or reuse; stage ../lib/<abi>/libzed_og.so (gitignored), and with an
#                                     Android OUT_DIR also OUT_DIR/og-zed/<abi>/libzed_og.so (relative to the
#                                     current directory, or absolute)
#   zed.sh --key <abi>                print the cache key
#   zed.sh --source                   fetch, verify and patch the source only; print its directory
#   zed.sh --verify <abi>             two builds into fresh target dirs; fails unless the libraries are byte-identical
#   zed.sh --pin                      download the tarball, check it against the tag's git tree, print its sha256
#
# Environment: OG_ZED_CACHE (default ${XDG_CACHE_HOME:-~/.cache}/og-zed), OG_ZED_JOBS (default 4), OG_ZED_COLD=1 (a
# fresh cargo home and target dir for this run, for measuring a cold build; removed afterwards).
set -euo pipefail
# Errors inside $(...) must stop the script too (bash drops -e in command substitutions otherwise).
shopt -s inherit_errexit

here=$(cd "$(dirname "$0")" && pwd)
mod=$(dirname "$here")
# shellcheck source=pins
. "$here/pins"

cache=${OG_ZED_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/og-zed}
jobs=${OG_ZED_JOBS:-4}
profile=og-poc
# Path-independent output: container paths are fixed already, and these keep panic locations and C __FILE__ strings
# free of them anyway. --config appends to the tree's [build] rustflags (RUSTFLAGS would replace them).
rustflags='["--remap-path-prefix=/src=/zed", "--remap-path-prefix=/cargo-home=/cargo"]'
cflags='-ffile-prefix-map=/src=/zed -ffile-prefix-map=/cargo-home=/cargo'
# Git as a plain tool: no host or user configuration may change tree hashes or line endings.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

log() { echo "zed.sh: $*" >&2; }
die() { log "$*"; exit 1; }
triple() {
    case $1 in
        x86_64) echo x86_64-linux-android ;;
        arm64) echo aarch64-linux-android ;;
        *) die "unknown abi '$1' (x86_64 or arm64)" ;;
    esac
}
sha() { sha256sum "$@" | cut -d' ' -f1; }

# Toolchain identity: the recipe and its pins (the base image by digest, the package snapshot, Rust and the NDK).
toolchain_id() {
    { cat "$here/toolchain/Dockerfile"; grep -E '^(RUST|NDK|TOOLCHAIN|APT)_' "$here/pins"; } | sha256sum | cut -c1-16
}

key() {
    local abi=$1
    {
        echo "abi=$abi profile=$profile rustflags=$rustflags cflags=$cflags"
        cat "$here/pins" "$here/zed.sh" "$mod/Cargo.lock"
        for p in "$mod"/patches/*.patch; do echo "== $(basename "$p")"; cat "$p"; done
        echo "toolchain=$(toolchain_id)"
    } | sha256sum | cut -c1-32
}

fetch() { # <url> <sha256> <dest>
    local url=$1 want=$2 dest=$3
    if [ ! -f "$dest" ] || [ "$(sha "$dest")" != "$want" ]; then
        log "fetching $url"
        curl -fsSL --proto '=https' --retry 3 -o "$dest.part" "$url"
        [ "$(sha "$dest.part")" = "$want" ] || { rm -f "$dest.part"; die "sha256 mismatch for $url"; }
        mv "$dest.part" "$dest"
    fi
}

# The tarball's tree must hash to the tag's git tree: an independent check that also lets --pin bootstrap the sha256.
extract_checked() { # <tarball> <dir>
    local tb=$1 dir=$2
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xzf "$tb" -C "$dir" --strip-components=1
    (cd "$dir" && git init -q && git -c core.autocrlf=false -c core.fileMode=true add -A -f)
    local tree
    tree=$(git -C "$dir" write-tree)
    [ "$tree" = "$ZED_TAG_TREE" ] || die "the tarball's tree $tree is not $ZED_TAG ($ZED_TAG_TREE)"
}

source_tree() { # prints the patched, read-only source dir
    local skey dir tb
    skey=$( { echo "$ZED_TARBALL_SHA256"; cat "$mod/Cargo.lock" "$mod"/patches/*.patch; } | sha256sum | cut -c1-16)
    dir=$cache/src/$skey
    if [ ! -f "$dir/.og-zed-ok" ]; then
        [ "$ZED_TARBALL_SHA256" != PIN-ME ] || die "ZED_TARBALL_SHA256 is not pinned yet (zed.sh --pin)"
        mkdir -p "$cache/dl"
        tb=$cache/dl/zed-$ZED_TAG.tar.gz
        fetch "$ZED_TARBALL_URL" "$ZED_TARBALL_SHA256" "$tb"
        [ -d "$dir" ] && chmod -R u+w "$dir"
        extract_checked "$tb" "$dir"
        (
            cd "$dir"
            export GIT_AUTHOR_DATE="@$SOURCE_DATE_EPOCH" GIT_COMMITTER_DATE="@$SOURCE_DATE_EPOCH"
            git -c user.name=og-os -c user.email=og-os@invalid commit -q -m "$ZED_TAG"
            git -c user.name=og-os -c user.email=og-os@invalid am -q --committer-date-is-author-date "$mod"/patches/*.patch
        ) || die "the patch series does not apply to $ZED_TAG"
        cmp -s "$dir/Cargo.lock" "$mod/Cargo.lock" || die "the patched Cargo.lock differs from $mod/Cargo.lock"
        rm -rf "$dir/.git"
        touch "$dir/.og-zed-ok"
        chmod -R a-w "$dir"
        log "source: $ZED_TAG + $(ls "$mod"/patches/*.patch | wc -l) patches in $dir"
    fi
    echo "$dir"
}

toolchain_image() { # prints the image name, building it from pinned inputs if missing
    local img f
    img=og-zed-toolchain:$RUST_VERSION-$NDK_VERSION-$(toolchain_id)
    if ! docker image inspect "$img" > /dev/null 2>&1; then
        case "$TOOLCHAIN_BASE_IMAGE $APT_SNAPSHOT" in *PIN-ME*) die "TOOLCHAIN_BASE_IMAGE / APT_SNAPSHOT are not pinned yet" ;; esac
        f=$cache/fetch; mkdir -p "$f"
        fetch "$RUST_DIST_URL/rust-$RUST_VERSION-x86_64-unknown-linux-gnu.tar.xz" "$RUST_HOST_SHA256" \
            "$f/rust-$RUST_VERSION-x86_64-unknown-linux-gnu.tar.xz"
        fetch "$RUST_DIST_URL/rust-std-$RUST_VERSION-x86_64-linux-android.tar.xz" "$RUST_STD_X86_64_SHA256" \
            "$f/rust-std-$RUST_VERSION-x86_64-linux-android.tar.xz"
        fetch "$RUST_DIST_URL/rust-std-$RUST_VERSION-aarch64-linux-android.tar.xz" "$RUST_STD_AARCH64_SHA256" \
            "$f/rust-std-$RUST_VERSION-aarch64-linux-android.tar.xz"
        fetch "$NDK_URL" "$NDK_ZIP_SHA256" "$f/android-ndk-$NDK_VERSION-linux.zip"
        # The recipe re-checks the files itself (sha256 for Rust, Google's sha1 for the NDK).
        echo "$RUST_HOST_SHA256  rust-$RUST_VERSION-x86_64-unknown-linux-gnu.tar.xz" \
            > "$f/rust-$RUST_VERSION-x86_64-unknown-linux-gnu.tar.xz.sha256"
        echo "$RUST_STD_X86_64_SHA256  rust-std-$RUST_VERSION-x86_64-linux-android.tar.xz" \
            > "$f/rust-std-$RUST_VERSION-x86_64-linux-android.tar.xz.sha256"
        echo "$RUST_STD_AARCH64_SHA256  rust-std-$RUST_VERSION-aarch64-linux-android.tar.xz" \
            > "$f/rust-std-$RUST_VERSION-aarch64-linux-android.tar.xz.sha256"
        echo "$NDK_ZIP_SHA1" > "$f/ndk.sha1.google"
        local ca
        for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem ""; do
            [ -z "$ca" ] || [ -s "$ca" ] && break
        done
        [ -n "$ca" ] || die "no CA bundle on this host (needed for apt's https to the snapshot server)"
        cp "$ca" "$f/host-ca.crt"
        log "building $img"
        # The only network use is apt, from the dated Ubuntu snapshot.
        docker build -q -t "$img" --build-arg BASE_IMAGE="$TOOLCHAIN_BASE_IMAGE" --build-arg APT_SNAPSHOT="$APT_SNAPSHOT" \
            -f "$here/toolchain/Dockerfile" "$f" > /dev/null
    fi
    echo "$img"
}

# The build sandbox: no network, no capabilities, read-only source, the cargo home read-only under a throwaway tmpfs
# CARGO_HOME, 8 CPUs and 24 GB at most.
sandbox() { # <img> <src> <target dir> <cargo home> <cmd...>
    local img=$1 src=$2 tgt=$3 ch=$4; shift 4
    docker run --rm --network none --cpus 8 --memory 24g \
        --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
        -v "$src:/src:ro" -v "$tgt:/target" \
        --tmpfs /cargo-home:rw,exec,uid="$(id -u)",gid="$(id -g)",size=8g \
        -v "$ch/registry/index:/cargo-home/registry/index:ro" \
        -v "$ch/registry/cache:/cargo-home/registry/cache:ro" \
        -v "$ch/registry/src:/cargo-home/registry/src:ro" \
        -v "$ch/git:/cargo-home/git:ro" \
        -e CARGO_TARGET_DIR=/target -e CARGO_BUILD_JOBS="$jobs" -e CARGO_NET_OFFLINE=true \
        -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
        -e CFLAGS_x86_64_linux_android="$cflags" -e CFLAGS_aarch64_linux_android="$cflags" \
        -e CXXFLAGS_x86_64_linux_android="$cflags" -e CXXFLAGS_aarch64_linux_android="$cflags" \
        "$img" bash -c '. /src/og-os/docker/og-zed-env.sh; exec nice -n 19 "$@"' sh "$@"
}

crates() { # <img> <src> <cargo home>: offline check first; the networked fetch only when something is missing
    local img=$1 src=$2 ch=$3
    mkdir -p "$ch/registry/index" "$ch/registry/cache" "$ch/registry/src" "$ch/git"
    # All platforms, not just the two targets: cargo build also needs the host-side packages of build scripts and
    # proc-macros (alsa, for one, when the build host is Linux), which a --target-filtered fetch leaves out.
    if sandbox "$img" "$src" "$(mktemp -d)" "$ch" cargo fetch --locked --offline > /dev/null 2>&1; then
        return
    fi
    log "cargo fetch --locked (network)"
    docker run --rm --cpus 4 --memory 8g --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
        -v "$src:/src:ro" -v "$ch:/cargo-home" -e CARGO_HOME=/cargo-home -e CARGO_NET_OFFLINE=false \
        "$img" cargo fetch --locked
}

build_into() { # <abi> <img> <src> <cargo home> <target dir>: prints the built library
    local abi=$1 img=$2 src=$3 ch=$4 tgt=$5 t
    t=$(triple "$abi")
    mkdir -p "$tgt"
    sandbox "$img" "$src" "$tgt" "$ch" cargo build --locked -p zed_og --target "$t" --profile "$profile" \
        --config "build.rustflags=$rustflags" >&2
    echo "$tgt/$t/$profile/libzed_og.so"
}

stage() { # <abi> <library> [OUT_DIR]
    local abi=$1 lib=$2 out=${3:-} dirs
    dirs=("$mod/lib/$abi")
    [ -z "$out" ] || dirs+=("$(realpath -m "$out")/og-zed/$abi")
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
        cp --reflink=auto "$lib" "$d/libzed_og.so.tmp"
        mv -f "$d/libzed_og.so.tmp" "$d/libzed_og.so"
        key "$abi" > "$d/KEY"
    done
    log "staged $abi: $(sha "$lib") in ${dirs[*]}"
}

main_build() { # <abi> [OUT_DIR]
    local abi=$1 out=${2:-} k c src img ch tgt lib start
    triple "$abi" > /dev/null
    k=$(key "$abi"); c=$cache/out/$k
    mkdir -p "$cache"
    exec 7> "$cache/.lock-$abi"; flock 7
    if [ -f "$c/libzed_og.so" ] && [ "$(sha "$c/libzed_og.so")" = "$(cat "$c/libzed_og.so.sha256")" ]; then
        log "cache hit $abi $k"
        stage "$abi" "$c/libzed_og.so" "$out"
        return
    fi
    start=$(date +%s)
    src=$(source_tree)
    img=$(toolchain_image)
    if [ "${OG_ZED_COLD:-0}" = 1 ]; then
        ch=$cache/cold-$$/cargo-home; tgt=$cache/cold-$$/target
    else
        ch=$cache/cargo-home; tgt=$cache/target
    fi
    crates "$img" "$src" "$ch"
    lib=$(build_into "$abi" "$img" "$src" "$ch" "$tgt")
    mkdir -p "$c"
    cp "$lib" "$c/libzed_og.so.tmp"; mv "$c/libzed_og.so.tmp" "$c/libzed_og.so"
    sha "$c/libzed_og.so" > "$c/libzed_og.so.sha256"
    {
        echo "key $k abi $abi built $(date -u +%FT%TZ) wall_s $(( $(date +%s) - start ))"
        echo "image $img $(docker image inspect --format '{{.Id}}' "$img")"
        echo "sha256 $(cat "$c/libzed_og.so.sha256")"
    } > "$c/RECORD"
    if [ "${OG_ZED_COLD:-0}" = 1 ]; then
        log "cold run: cargo home $(du -sh "$ch" | cut -f1), target $(du -sh "$tgt" | cut -f1)"
        chmod -R u+w "$cache/cold-$$"; rm -rf "$cache/cold-$$"
    fi
    stage "$abi" "$c/libzed_og.so" "$out"
}

case ${1:-} in
    --key) key "${2:?abi}" ;;
    --source) source_tree ;;
    --pin)
        mkdir -p "$cache/dl"; tb=$cache/dl/zed-$ZED_TAG.tar.gz.unpinned
        curl -fsSL --proto '=https' --retry 3 -o "$tb" "$ZED_TARBALL_URL"
        extract_checked "$tb" "$(mktemp -d)"
        echo "ZED_TARBALL_SHA256=$(sha "$tb")   # matches $ZED_TAG's git tree $ZED_TAG_TREE"
        ;;
    --verify)
        abi=${2:?abi}; src=$(source_tree); img=$(toolchain_image); crates "$img" "$src" "$cache/cargo-home"
        v=$cache/verify-$$; a=$(build_into "$abi" "$img" "$src" "$cache/cargo-home" "$v/a")
        b=$(build_into "$abi" "$img" "$src" "$cache/cargo-home" "$v/b")
        echo "a $(sha "$a")"; echo "b $(sha "$b")"
        cmp "$a" "$b" && echo "REPRODUCIBLE $abi" || { echo "NOT REPRODUCIBLE $abi (kept in $v)"; exit 1; }
        rm -rf "$v"
        ;;
    x86_64 | arm64) main_build "$@" ;;
    *) sed -n '4,25p' "$0" >&2; exit 2 ;;
esac
