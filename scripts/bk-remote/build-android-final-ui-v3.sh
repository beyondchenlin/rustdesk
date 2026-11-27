#!/usr/bin/env bash
set -Eeuo pipefail
if test "$#" != 3; then
  echo "Usage: $0 <successful-native-run-directory> <debug|unsigned-release> <prepared-v3-ui-evidence-directory>" >&2
  exit 2
fi
ROOT="${BK_TOOLCHAIN_ROOT:-/mnt/d/demo2/bk-remote-toolchains}"
NATIVE="$(realpath "$1")"
MODE="$2"
case "$MODE" in debug|unsigned-release) ;; *) echo "Invalid validation mode" >&2; exit 2;; esac
test "$(cat "$NATIVE/exit-code.txt")" = 0
UI_EVIDENCE=""
if test "$#" = 3; then
  UI_EVIDENCE="$(realpath "$3")"
  SOURCE="$(cat "$UI_EVIDENCE/snapshot-path.txt")"
else
  SOURCE="$(cat "$NATIVE/snapshot-path.txt")"
fi
test -f "$SOURCE/flutter/pubspec.yaml"
exec 9>"$ROOT/bk-android-package.lock"
flock -n 9 || { echo "Another BK Android package build is running" >&2; exit 1; }
RUN="$ROOT/android-validation-$MODE-$(date +%Y%m%d-%H%M%S)"
mkdir "$RUN"
printf '%s\n' "$RUN" > "$ROOT/current-g2-package-run.txt"
exec > >(tee "$RUN/package.log") 2>&1
trap 'rc=$?; printf "%s\n" "$rc" > "$RUN/exit-code.txt"; echo "ANDROID_VALIDATION_EXIT=$rc"; exit "$rc"' EXIT
printf 'NATIVE=%s\nSOURCE=%s\nMODE=%s\n' "$NATIVE" "$SOURCE" "$MODE"
(cd "$NATIVE" && sha256sum -c native-output.sha256)
# Verification tools are versioned separately from the immutable compiled source.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sha256sum "${BASH_SOURCE[0]}" "$SCRIPT_DIR/verify-android-native.py" > "$RUN/verification-tools.sha256"
if test -n "$UI_EVIDENCE"; then
  sha256sum "$SCRIPT_DIR/prepare-final-ui-snapshots-v3.py" "$SCRIPT_DIR/prepare-android-ui-snapshot.py" >> "$RUN/verification-tools.sha256"
  python3 "$SCRIPT_DIR/prepare-final-ui-snapshots-v3.py" verify-android "$UI_EVIDENCE" --native-run "$NATIVE" --binary-report "$RUN/native-validation.json"
  for evidence in approval.json receipt.json native-tree.json ui-tree.json native-inspection.json; do
    install -m 644 "$UI_EVIDENCE/$evidence" "$RUN/ui-$evidence"
  done
  echo "NATIVE_RECOMPILED=false"
else
  python3 "$SCRIPT_DIR/verify-android-native.py" "$NATIVE"
  python3 - "$SOURCE" "$NATIVE/source-manifest.json" <<'PY'
import hashlib,json,pathlib,sys
source,manifest=map(pathlib.Path,sys.argv[1:])
data=json.loads(manifest.read_text())
for item in data['changed']:
    assert hashlib.sha256((source/item['path']).read_bytes()).hexdigest()==item['snapshot_sha256'],item['path']
for name,expected in data['bridges'].items():
    assert hashlib.sha256((source/name).read_bytes()).hexdigest()==expected,name
print('FROZEN_INPUTS_VERIFIED')
PY
fi
P="$ROOT/wsl-build-env"
FLUTTER="$ROOT/flutter-3.24.5"
SDK=/mnt/d/demo2/bk-remote-android-sdk
NDK=/home/ai/bk-remote-build/android-ndk-r28c
export CONDA_PREFIX="$P" JAVA_HOME="$P" ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK" ANDROID_NDK_HOME="$NDK" ANDROID_NDK_ROOT="$NDK"
export ANDROID_USER_HOME="$ROOT/android-user-home"
export PUB_CACHE="$ROOT/pub-cache" PUB_HOSTED_URL=https://pub.dev GRADLE_USER_HOME="$ROOT/gradle-home" CI=true FLUTTER_SUPPRESS_ANALYTICS=true
# AGP otherwise chooses its own NDK version. Reuse the already verified r28c.
export BK_ANDROID_PACKAGE_SOURCE="$SOURCE"
grep -Eq '^Pkg.Revision[[:space:]]*=[[:space:]]*28.2.13676358$' "$SDK/ndk/28.2.13676358/source.properties"
test -x "$SDK/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
mkdir -p "$GRADLE_USER_HOME/init.d"
INIT="$GRADLE_USER_HOME/init.d/bk-android-ndk-r28c.gradle"
if test -f "$INIT"; then cmp "$SCRIPT_DIR/android-package-ndk.init.gradle" "$INIT"; else install -m 644 "$SCRIPT_DIR/android-package-ndk.init.gradle" "$INIT"; fi
sha256sum "$SCRIPT_DIR/android-package-ndk.init.gradle" >> "$RUN/verification-tools.sha256"
export RUSTUP_HOME="$ROOT/rustup-home" CARGO_HOME="$ROOT/cargo-home" RUSTUP_TOOLCHAIN=1.98.1 CARGO_NET_OFFLINE=true
export PATH="$P/bin:$FLUTTER/bin:$CARGO_HOME/bin:$SDK/platform-tools:$SDK/cmdline-tools/latest/bin:$PATH"
export CARGO_BUILD_JOBS=2
export ORG_GRADLE_PROJECT_bkUnsignedValidation=false
JNI="$SOURCE/flutter/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI" "$ANDROID_USER_HOME"
for pair in 'liblibrustdesk.so:librustdesk.so' 'libc++_shared.so:libc++_shared.so'; do
  from=${pair%%:*}; to=${pair#*:}
  if test -f "$JNI/$to"; then cmp "$NATIVE/$from" "$JNI/$to"; else cp "$NATIVE/$from" "$JNI/$to"; fi
done
cd "$SOURCE/flutter"
sha256sum pubspec.lock ../Cargo.lock > "$RUN/locks-before.sha256"
printf 'sdk.dir=%s\nflutter.sdk=%s\n' "$SDK" "$FLUTTER" > android/local.properties
flutter pub get --offline --enforce-lockfile
sha256sum -c "$RUN/locks-before.sha256"
BUILD_MODE=debug
if test "$MODE" = unsigned-release; then
  BUILD_MODE=release
  export ORG_GRADLE_PROJECT_bkUnsignedValidation=true
fi
flutter build apk "--$BUILD_MODE" --split-per-abi --target-platform android-arm64 --no-pub
sha256sum -c "$RUN/locks-before.sha256"
APK="$SOURCE/flutter/build/app/outputs/flutter-apk/app-arm64-v8a-$BUILD_MODE.apk"
test -s "$APK"
OUT="$RUN/bk-remote-1.5.3-71-arm64-$MODE-validation.apk"
cp "$APK" "$OUT"
sha256sum "$OUT" > "$RUN/package.sha256"
printf '%s\n' "$OUT" > "$RUN/package-path.txt"
echo ANDROID_VALIDATION_PACKAGE_PASS
