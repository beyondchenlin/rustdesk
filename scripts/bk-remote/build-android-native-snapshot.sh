#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${BK_TOOLCHAIN_ROOT:-/mnt/d/demo2/bk-remote-toolchains}"
REPO="${BK_CLIENT_ROOT:-/mnt/d/demo2/rustdesk}"
P="$ROOT/wsl-build-env"
NDK=/home/ai/bk-remote-build/android-ndk-r28c
VCPKG_ROOT="$ROOT/vcpkg"
BASE=a0c0963c483fc8f1aeed4547787d1673adcb583c
COMMON=450cc1d7b729cfa8d19b5a7527c9cc2fe54cf5eb
RUN="$ROOT/android-g2-continuation-$(date +%Y%m%d-%H%M%S)"
SOURCE="/home/ai/bk-remote-build/$(basename "$RUN")-source"
TARGET=aarch64-linux-android
exec 9>"$ROOT/bk-android-native.lock"
flock -n 9 || { echo "Another BK Android native build is running"; exit 1; }
mkdir "$RUN"
printf '%s\n' "$RUN" > "$ROOT/current-g2-continuation-native-run.txt"
exec > >(tee "$RUN/native.log") 2>&1
trap 'rc=$?; printf "%s\n" "$rc" > "$RUN/exit-code.txt"; echo "ANDROID_NATIVE_EXIT=$rc"; exit "$rc"' EXIT
echo "RUN=$RUN"
export RUSTUP_HOME="$ROOT/rustup-home" CARGO_HOME="$ROOT/cargo-home" RUSTUP_TOOLCHAIN=1.98.1
export PATH="$P/bin:$CARGO_HOME/bin:$VCPKG_ROOT:$PATH"
# Android resolves bundled JNI libraries through its app loader, not build-host paths.
export CARGO_PROFILE_RELEASE_RPATH=false
export CARGO_BUILD_JOBS=4 CARGO_TARGET_DIR=/home/ai/bk-remote-build/rust-target
export ANDROID_NDK_HOME="$NDK" ANDROID_NDK_ROOT="$NDK"
export VCPKG_ROOT VCPKG_INSTALLED_ROOT="$VCPKG_ROOT/installed"
export LIBCLANG_PATH="$NDK/toolchains/llvm/prebuilt/linux-x86_64/lib" CARGO_NET_RETRY=3 CARGO_HTTP_TIMEOUT=90 CARGO_HTTP_LOW_SPEED_LIMIT=1 CARGO_HTTP_MULTIPLEXING=false
export CARGO_NET_GIT_FETCH_WITH_CLI=true GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1 GIT_TERMINAL_PROMPT=0
export HOST_CC="$P/bin/gcc" HOST_CXX="$P/bin/g++" PERL="$P/bin/perl"
llvm="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
sysroot="$llvm/../sysroot"
resource_dir="$llvm/../lib/clang/19"
test -s "$resource_dir/include/stddef.h"
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-android21 --sysroot=$sysroot -resource-dir=$resource_dir"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="$BINDGEN_EXTRA_CLANG_ARGS"
export CFLAGS_aarch64_linux_android="--target=aarch64-linux-android21"
export CXXFLAGS_aarch64_linux_android="--target=aarch64-linux-android21"
unset CC CXX AR RANLIB PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR OPENSSL_DIR OPENSSL_NO_VENDOR
test "$(git -C "$REPO" rev-parse HEAD)" = "$BASE"
test "$(git -C "$REPO/libs/hbb_common" rev-parse HEAD)" = "$COMMON"
test "$(git -C "$VCPKG_ROOT" rev-parse HEAD)" = 9e593bb18ea69cc5095e012465dcd675a822ed0d
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*28.2.13676358$' "$NDK/source.properties"
rustc --version
test "$(cargo ndk --version)" = 'cargo-ndk 3.1.2'
test -s "$LIBCLANG_PATH/libclang.so"
printf '#include <stdint.h>\n#include <stddef.h>\n' | "$llvm/clang" --target=aarch64-linux-android21 --sysroot="$sysroot" -x c -fsyntax-only -
for lib in aom avcodec avformat avutil cpu_features jpeg ndk_compat opus turbojpeg vpx yuv; do
    f="$VCPKG_INSTALLED_ROOT/arm64-android/lib/lib$lib.a"
    test -s "$f"
    "$llvm/llvm-readelf" -h "$f" | awk '/Machine:/ {n++;if ($0 !~ /AArch64/) bad=1} END{if(!n||bad)exit 1; print "ARCHIVE_MEMBERS="n}'
    sha256sum "$f"
done > "$RUN/verified-archives.txt"
echo "NATIVE_DEPENDENCIES_VERIFIED"
test ! -e "$SOURCE"
mkdir "$SOURCE"
git -C "$REPO" archive --format=tar "$BASE" | tar -xf - -C "$SOURCE"
mkdir -p "$SOURCE/libs/hbb_common"
git -C "$REPO/libs/hbb_common" archive --format=tar "$COMMON" | tar -xf - -C "$SOURCE/libs/hbb_common"
python3 - "$REPO" "$SOURCE" "$RUN" <<'PY'
import hashlib,json,pathlib,subprocess,sys
repo,src,run=map(pathlib.Path,sys.argv[1:])
def git(*args):
    return subprocess.check_output(['git','-c','core.filemode=false','-c','core.autocrlf=false','-c','core.safecrlf=false','-C',str(repo),*args])
def norm(b):return b.replace(b'\r\n',b'\n')
def digest(b):return hashlib.sha256(b).hexdigest()
paths=git('diff','--ignore-submodules=all','--name-only','-z','HEAD','--').decode().split('\0')
common=repo/'libs/hbb_common'
def sg(*args):return subprocess.check_output(['git','-c','core.filemode=false','-c','core.safecrlf=false','-C',str(common),*args])
for p in filter(None,sg('diff','--ignore-submodules=all','--name-only','-z','HEAD','--').decode().split('\0')):
    if norm((common/p).read_bytes())!=norm(sg('show','HEAD:'+p)):raise SystemExit('Submodule source changed: '+p)
if sg('ls-files','--others','--exclude-standard','-z'):raise SystemExit('Unexpected submodule untracked files')
text_suffixes={'.rs','.dart','.kt','.sh','.ps1','.py','.json','.md','.xml','.gradle','.toml','.lock','.rc','.cmake','.txt','.h','.cpp','.c','.yaml','.yml','.svg','.bat','.patch','.diff'}
def snapshot_bytes(p,b):
    return norm(b) if pathlib.Path(p).suffix.lower() in text_suffixes and b'\0' not in b else b
allowed_prefixes=('src/','flutter/lib/','flutter/test/','flutter/android/','flutter/windows/','assets/brand/','docs/prd/bk-remote-20261126/','docs/tech/bk-remote-20261126/','scripts/bk-remote/')
allowed_exact={'res/icon.png','res/icon.ico','res/tray-icon.ico','flutter/assets/icon.png','libs/portable/Cargo.toml','libs/portable/build.rs','libs/portable/src/main.rs','Cargo.toml'}
changed=[]; eol=[]; source_hashes={}
for p in filter(None,paths):
    b=(repo/p).read_bytes()
    baseline=git('show','HEAD:'+p)
    if snapshot_bytes(p,b)==snapshot_bytes(p,baseline):
        eol.append(p)
        continue
    if not p.startswith(allowed_prefixes) and p not in allowed_exact:
        raise SystemExit('Unexpected material source change: '+p)
    (src/p).parent.mkdir(parents=True,exist_ok=True)
    output=snapshot_bytes(p,b)
    (src/p).write_bytes(output)
    source_hashes[p]=digest(b)
    changed.append({'path':p,'source_sha256':digest(b),'snapshot_sha256':digest(output)})
untracked=git('ls-files','--others','--exclude-standard','-z').decode().split('\0')
extra=['assets/brand/BK-Remote-Official-Logo.png','flutter/assets/icon.png']
for p in sorted(set(filter(None,untracked+extra))):
    if not p.startswith(allowed_prefixes) and p not in allowed_exact:
        raise SystemExit('Unreviewed untracked path: '+p)
    b=(repo/p).read_bytes()
    output=snapshot_bytes(p,b)
    (src/p).parent.mkdir(parents=True,exist_ok=True)
    (src/p).write_bytes(output)
    source_hashes[p]=digest(b)
    changed.append({'path':p,'source_sha256':digest(b),'snapshot_sha256':digest(output),'added':True})
for p,h in source_hashes.items():
    if digest((repo/p).read_bytes())!=h:raise SystemExit('Concurrent source mutation: '+p)
bridges={
'src/bridge_generated.rs':'6019a863cae2bd85e12993de1e926313454a668f935894c4bfa71a4e2c3f4c39',
'src/bridge_generated.io.rs':'e481a83c090d10277da4020b3d724deedfddfc2cc44862a259b98ebfcc1813b4',
'flutter/lib/generated_bridge.dart':'b68ea66847d48179fd3db828c516619c28d60853147d9ff99d83d9ce19951d8b',
'flutter/lib/generated_bridge.freezed.dart':'5c41889f95d46ef4b57eba34fc4c29b51e76efaada2abf51e6c0cbbc112ae3d4'}
for p,h in bridges.items():
    b=(repo/p).read_bytes()
    if digest(b)!=h:raise SystemExit('Bridge hash mismatch: '+p)
    (src/p).write_bytes(b)
for p in ('Cargo.lock','flutter/pubspec.lock'):
    if norm((repo/p).read_bytes())!=norm((src/p).read_bytes()):raise SystemExit('Lock changed: '+p)
(run/'source-manifest.json').write_text(json.dumps({'baseline':git('rev-parse','HEAD').decode().strip(),'changed':changed,'line_ending_only':eol,'bridges':bridges},indent=2))
print('SNAPSHOT_VERIFIED: material changes',len(changed),'line endings only',len(eol))
(run/'snapshot-path.txt').write_text(str(src)+'\n')
PY
cd "$SOURCE"
# Generate source-local version metadata even when reusing the target cache.
touch build.rs
sha256sum Cargo.lock > "$RUN/lock.before.sha256"
# Official entry point, normalized only in the isolated copy.
sed 's/\r$//' flutter/ndk_arm64.sh > "$RUN/upstream-ndk-arm64.sh"
bash "$RUN/upstream-ndk-arm64.sh"
sha256sum -c "$RUN/lock.before.sha256"
out="$CARGO_TARGET_DIR/$TARGET/release/liblibrustdesk.so"
test -s "$out"
"$llvm/llvm-readelf" -h "$out" > "$RUN/liblibrustdesk.elf.txt"
grep -Eq 'Machine:[[:space:]]+AArch64' "$RUN/liblibrustdesk.elf.txt"
grep -Eq 'Type:[[:space:]]+DYN' "$RUN/liblibrustdesk.elf.txt"
install -m 644 "$out" "$RUN/liblibrustdesk.so"
install -m 644 "$sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$RUN/libc++_shared.so"
(cd "$RUN" && sha256sum liblibrustdesk.so libc++_shared.so > native-output.sha256)
echo ANDROID_NATIVE_BUILD_PASS
