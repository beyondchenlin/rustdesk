#!/usr/bin/env bash
# Isolated Android native baseline. Keep the upstream codec and lock files.
set -Eeuo pipefail
umask 022
baseline=a0c0963c483fc8f1aeed4547787d1673adcb583c
ndk_revision=28.2.13676358
ndk_sha1=a7b54a5de87fecd125a17d54f73c446199e72a64
ndk_size=722261334
target=aarch64-linux-android
trap 'rc=$?; printf "ANDROID_LINUX_NATIVE_EXIT=%s\n" "$rc"; exit "$rc"' EXIT
test "$(uname -s)" = Linux
test "$(uname -m)" = x86_64
test -d /inputs -a -d /evidence -a -d /work
test "$(cat /inputs/baseline.txt | tr -d '\r\n')" = "$baseline"
(cd /inputs && sha256sum -c SHA256SUMS)
mkdir -p /work/downloads /work/source /work/target /evidence
if [[ -f /work/source/Cargo.toml ]]; then
    # Resume only this failed, isolated build after validating pinned inputs.
    test -f /inputs/resume-after-header-error.txt
    test -f /evidence/linux-native-lock.before.sha256
    cd /work/source
    sha256sum -c /evidence/linux-native-lock.before.sha256
    cmp src/bridge_generated.rs /inputs/bridge_generated.rs
    cmp src/bridge_generated.io.rs /inputs/bridge_generated.io.rs
    echo ANDROID_LINUX_RESUME_VERIFIED
else
    tar -xf /inputs/client.tar -C /work/source
    mkdir -p /work/source/libs/hbb_common
    tar -xf /inputs/hbb_common.tar -C /work/source/libs/hbb_common
    install -m 644 /inputs/bridge_generated.rs /work/source/src/bridge_generated.rs
    install -m 644 /inputs/bridge_generated.io.rs /work/source/src/bridge_generated.io.rs
    cd /work/source
    sha256sum Cargo.lock > /evidence/linux-native-lock.before.sha256
fi
# Google Android SDK repository metadata, ndk;28.2.13676358, linux archive.
archive=/work/downloads/android-ndk-r28c-linux.zip
if [[ ! -f "$archive" ]]; then
    curl -fL --retry 2 --connect-timeout 20 --max-time 1800 \
        https://dl.google.com/android/repository/android-ndk-r28c-linux.zip \
        -o "$archive.part"
    test "$(wc -c < "$archive.part" | tr -d ' ')" = "$ndk_size"
    printf '%s  %s\n' "$ndk_sha1" "$archive.part" | sha1sum -c -
    mv "$archive.part" "$archive"
fi
test "$(wc -c < "$archive" | tr -d ' ')" = "$ndk_size"
printf '%s  %s\n' "$ndk_sha1" "$archive" | sha1sum -c -
export ANDROID_NDK_HOME=/work/android-ndk-r28c
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
if [[ ! -f "$ANDROID_NDK_HOME/source.properties" ]]; then
    unzip -q "$archive" -d /work
fi
grep -Eq "^Pkg.Revision[[:space:]]*=[[:space:]]*$ndk_revision$" "$ANDROID_NDK_HOME/source.properties"
llvm="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
"$llvm/clang" --version
# Reuse the verified target-only archives built against the same NDK and
# upstream vcpkg pin. Check EVERY archive member's target before linking.
export VCPKG_ROOT=/vcpkg
export VCPKG_INSTALLED_ROOT=/vcpkg/installed
for lib in aom avcodec avformat avutil cpu_features jpeg ndk_compat opus turbojpeg vpx yuv; do
    input="/vcpkg/installed/arm64-android/lib/lib$lib.a"
    test -s "$input"
    "$llvm/llvm-readelf" -h "$input" | awk '
        /Machine:/ { n++; if ($0 !~ /AArch64/) bad=1 }
        END { if (!n || bad) exit 1; print "AArch64 archive members:", n }'
    sha256sum "$input"
done
# Linux-host Rust builds use the same Rust release as the existing local
# baseline, with the upstream cargo-ndk and NDK/API-level pins.
rustup toolchain install 1.98.1 --profile minimal --target "$target"
export RUSTUP_TOOLCHAIN=1.98.1
# Do not embed build-host search paths in Android release libraries.
export CARGO_PROFILE_RELEASE_RPATH=false
export CARGO_BUILD_JOBS=1
export CARGO_TARGET_DIR=/work/target
rustc --version
cargo install cargo-ndk --version 3.1.2 --locked --jobs 1
test "$(cargo ndk --version)" = 'cargo-ndk 3.1.2'
export LIBCLANG_PATH="$llvm/../lib"
test -s "$LIBCLANG_PATH/libclang.so"
resource_dir="$llvm/../lib/clang/19"
test -s "$resource_dir/include/stddef.h"
# Bindgen must see Android target headers, not Linux-host libc headers.
sysroot="$llvm/../sysroot"
test -f "$sysroot/usr/include/stdint.h"
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android21 --sysroot=$sysroot -resource-dir=$resource_dir"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="$BINDGEN_EXTRA_CLANG_ARGS"
# Verify the same target/header combination before invoking Cargo.
printf '#include <stdint.h>\n#include <stddef.h>\n' |
    "$llvm/clang" --target=aarch64-linux-android21 --sysroot="$sysroot" -x c -fsyntax-only -
echo ANDROID_LINUX_TARGET_HEADERS_PASS
export CARGO_NET_RETRY=2
# Reuse locked OpenSSL built for Android only, not a host library.
export AARCH64_LINUX_ANDROID_OPENSSL_NO_VENDOR=1
export AARCH64_LINUX_ANDROID_OPENSSL_DIR=/openssl
export AARCH64_LINUX_ANDROID_OPENSSL_STATIC=1
for lib in ssl crypto; do
    "$llvm/llvm-readelf" -h "/openssl/lib/lib$lib.a" | awk '
        /Machine:/ { n++; if ($0 !~ /AArch64/) bad=1 }
        END { if (!n || bad) exit 1 }'
done
echo ANDROID_LINUX_TOOLCHAIN_PRECHECK_PASS
# Exactly the official Android build entry point, retaining hwcodec.
# Force source-local version metadata when reusing a target cache.
touch build.rs
bash flutter/ndk_arm64.sh
sha256sum -c /evidence/linux-native-lock.before.sha256
out="$CARGO_TARGET_DIR/$target/release/liblibrustdesk.so"
test -s "$out"
"$llvm/llvm-readelf" -h "$out" > /evidence/linux-native-elf.txt
grep -Eq 'Machine:[[:space:]]+AArch64' /evidence/linux-native-elf.txt
grep -Eq 'Type:[[:space:]]+DYN' /evidence/linux-native-elf.txt
install -m 644 "$out" /evidence/liblibrustdesk.so
install -m 644 "$llvm/../sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" /evidence/libc++_shared.so
(cd /evidence && sha256sum liblibrustdesk.so libc++_shared.so > linux-native-output.sha256)
echo ANDROID_LINUX_NATIVE_BUILD_PASS
