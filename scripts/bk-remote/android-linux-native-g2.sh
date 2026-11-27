#!/usr/bin/env bash
# G2 Android native rebuild: apply only reviewed localization changes to the
# isolated G1 source snapshot, then reuse the pinned Rust/NDK build cache.
set -Eeuo pipefail
umask 022

baseline=a0c0963c483fc8f1aeed4547787d1673adcb583c
ndk_revision=28.2.13676358
target=aarch64-linux-android
trap 'rc=$?; printf "ANDROID_G2_NATIVE_EXIT=%s\n" "$rc"; exit "$rc"' EXIT

test "$(uname -s)" = Linux
test "$(uname -m)" = x86_64
test -d /inputs/lang -a -d /evidence -a -d /work/source
test "$(tr -d '\r\n' < /inputs/baseline.txt)" = "$baseline"

cd /work/source
sha256sum -c /evidence/linux-native-lock.before.sha256
cmp src/bridge_generated.rs /inputs/bridge_generated.rs
cmp src/bridge_generated.io.rs /inputs/bridge_generated.io.rs
(cd /inputs/lang && sha256sum -c SHA256SUMS)

for name in en cn tw template; do
    install -m 644 "/inputs/lang/$name.rs" "src/lang/$name.rs"
done

# Prove that only the four reviewed translation tables were overlaid.
for name in en cn tw template; do
    cmp "src/lang/$name.rs" "/inputs/lang/$name.rs"
done
sha256sum -c /evidence/linux-native-lock.before.sha256

export ANDROID_NDK_HOME=/work/android-ndk-r28c
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
grep -Eq "^Pkg.Revision[[:space:]]*=[[:space:]]*$ndk_revision$" "$ANDROID_NDK_HOME/source.properties"
llvm="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
sysroot="$llvm/../sysroot"
test -f "$sysroot/usr/include/stdint.h"

export VCPKG_ROOT=/vcpkg
export VCPKG_INSTALLED_ROOT=/vcpkg/installed
for lib in aom avcodec avformat avutil cpu_features jpeg ndk_compat opus turbojpeg vpx yuv; do
    archive="/vcpkg/installed/arm64-android/lib/lib$lib.a"
    test -s "$archive"
    "$llvm/llvm-readelf" -h "$archive" | awk '
        /Machine:/ { n++; if ($0 !~ /AArch64/) bad=1 }
        END { if (!n || bad) exit 1 }'
done

export RUSTUP_TOOLCHAIN=1.98.1
# Do not embed build-host search paths in Android release libraries.
export CARGO_PROFILE_RELEASE_RPATH=false
export CARGO_BUILD_JOBS=1
export CARGO_TARGET_DIR=/work/target
export LIBCLANG_PATH="$llvm/../lib"
test -s "$LIBCLANG_PATH/libclang.so"
resource_dir="$llvm/../lib/clang/19"
test -s "$resource_dir/include/stddef.h"
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android21 --sysroot=$sysroot -resource-dir=$resource_dir"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="$BINDGEN_EXTRA_CLANG_ARGS"
export CARGO_NET_RETRY=2
export AARCH64_LINUX_ANDROID_OPENSSL_NO_VENDOR=1
export AARCH64_LINUX_ANDROID_OPENSSL_DIR=/openssl
export AARCH64_LINUX_ANDROID_OPENSSL_STATIC=1

rustc --version
test "$(cargo ndk --version)" = 'cargo-ndk 3.1.2'
printf '#include <stdint.h>\n#include <stddef.h>\n' |
    "$llvm/clang" --target=aarch64-linux-android21 --sysroot="$sysroot" -x c -fsyntax-only -
echo ANDROID_G2_NATIVE_TOOLCHAIN_PRECHECK_PASS

# Keep the upstream Android entry point and hardware-codec feature enabled.
# Force source-local version metadata when reusing a target cache.
touch build.rs
bash flutter/ndk_arm64.sh

sha256sum -c /evidence/linux-native-lock.before.sha256
out="$CARGO_TARGET_DIR/$target/release/liblibrustdesk.so"
test -s "$out"
"$llvm/llvm-readelf" -h "$out" > /evidence/g2-native-elf.txt
grep -Eq 'Machine:[[:space:]]+AArch64' /evidence/g2-native-elf.txt
grep -Eq 'Type:[[:space:]]+DYN' /evidence/g2-native-elf.txt
install -m 644 "$out" /evidence/liblibrustdesk.so
install -m 644 "$sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" /evidence/libc++_shared.so
(cd /evidence && sha256sum liblibrustdesk.so libc++_shared.so > g2-native-output.sha256)
echo ANDROID_G2_NATIVE_BUILD_PASS
