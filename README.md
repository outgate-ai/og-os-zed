# og-os-zed

The [Zed](https://zed.dev) code editor for [OG OS](https://outgate.ai), the Android-based OS by Outgate. OG OS
ships it as the app **Zed (preview)** (`ai.outgate.zed`): the editor running on an Android platform layer for
GPUI, without network, AI, collaboration, terminal or language-server features.

This repository holds no binaries: it is the patch series on top of an upstream Zed tag, and the script that
builds the app's native library, `libzed_og.so`, from them. It is the corresponding source of every OG OS release
that contains Zed (preview) (GPL-3.0-or-later, see [NOTICE.md](NOTICE.md)).

| Path | What |
|---|---|
| `patches/` | `git format-patch` series against the upstream tag in `build/pins` |
| `Cargo.lock` | the dependency lock of the patched tree (`zed.sh` checks it matches) |
| `build/zed.sh` | fetch, verify, patch, build, cache |
| `build/pins` | upstream tag, tarball sha256, `SOURCE_DATE_EPOCH`, toolchain pins |
| `build/toolchain/Dockerfile` | the build image: Rust and the Android NDK |
| `VERSION` | the inputs of the current release |
| `LICENSE-GPL`, `LICENSE-APACHE`, `NOTICE.md` | licences |

## Build

On a Linux x86_64 host with docker, curl and git:

```sh
build/zed.sh arm64      # phones (aarch64-linux-android)
build/zed.sh x86_64     # the emulator
```

The library lands in `lib/<abi>/libzed_og.so`. `zed.sh --verify <abi>` builds twice in fresh directories and
fails unless the two libraries are byte-identical.

What `zed.sh` does:

1. Downloads the upstream tag tarball and checks its sha256, and that its tree hashes to the tag's git tree.
2. Applies `patches/` with `git am`, at fixed dates, and checks the patched `Cargo.lock` against this one.
3. `cargo fetch --locked` for both Android targets: the only networked step. Cargo checks every crate against
   its `Cargo.lock` checksum; git dependencies are pinned by commit.
4. Builds the `og-zed-toolchain` image from `build/toolchain/Dockerfile` (base image by digest, Ubuntu packages
   from a dated snapshot, Rust and NDK downloads checked against `build/pins`).
5. `cargo build --locked -p zed_og --profile og-poc` in a container with no network, the source and crates
   read-only, and no capabilities; paths remapped and `SOURCE_DATE_EPOCH` set for a reproducible library.
6. Caches the result under `$OG_ZED_CACHE` (default `~/.cache/og-zed`), keyed by a hash of all of the above:
   unchanged inputs never rebuild.

## Releases

Each OG OS release that ships Zed (preview) has a tag here, `og-os-<release>`, whose `VERSION`, patches and
pins are exactly what that release was built from. The OS build runs `zed.sh` before the Android build and
packages the library into the app; the same files are carried in the OS tree at
`vendor/outgate/prebuilts/zed`.

## Upstream

Zed is © Zed Industries, Inc. and the Zed contributors: <https://github.com/zed-industries/zed>. This is not an
official Zed distribution and isn't affiliated with Zed Industries; "Zed" is their trademark.
