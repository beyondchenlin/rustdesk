[CmdletBinding()]
param(
    [ValidateSet('Check','Native','Package')][string]$Mode = 'Check',
    [string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$ToolchainRoot,
    [Parameter(Mandatory=$true)][string]$AndroidSdk,
    [Parameter(Mandatory=$true)][string]$JavaHome,
    [Parameter(Mandatory=$true)][string]$CacheRoot,
    [Parameter(Mandatory=$true)][string]$LibClangPath,
    [Parameter(Mandatory=$true)][string]$OpenSslRoot,
    [Parameter(Mandatory=$true)][string]$SodiumRoot,
    [string]$BaselineCommit = 'a0c0963c483fc8f1aeed4547787d1673adcb583c'
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Join-Path $PSScriptRoot '..\..'
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$OpenSslRoot = (Resolve-Path -LiteralPath $OpenSslRoot).Path
$SodiumRoot = (Resolve-Path -LiteralPath $SodiumRoot).Path
$rustBin = Join-Path $ToolchainRoot 'rustup-home\toolchains\1.98.1-x86_64-pc-windows-msvc\bin'
$cargoTools = Join-Path $ToolchainRoot 'cargo-tools\bin'
$flutterRoot = Join-Path $ToolchainRoot 'flutter-3.24.5'
$flutter = Join-Path $flutterRoot 'bin\flutter.bat'
$ndk = Join-Path $AndroidSdk 'ndk\28.2.13676358'
$llvm = Join-Path $ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin'
$vcpkgRoot = Join-Path $ToolchainRoot 'vcpkg'
$installed = Join-Path $ToolchainRoot 'vcpkg-android-installed'
$targetDir = Join-Path $ToolchainRoot 'android-arm64-target'
$target = 'aarch64-linux-android'
$head = (& git -C $RepoRoot rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $BaselineCommit) {
    throw "Unexpected baseline commit: $head"
}
& git -C $RepoRoot diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'Tracked source differs from baseline' }
$extra = @(& git -C $RepoRoot ls-files --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Cannot check untracked files' }
if (@($extra | Where-Object {
    $_ -notmatch '^(docs/|assets/brand/|scripts/bk-remote/)'
}).Count -ne 0) { throw 'Unexpected untracked source' }
$submodules = @(& git -C $RepoRoot submodule status --recursive)
if ($LASTEXITCODE -ne 0 -or @($submodules | Where-Object { $_ -match '^[-+U]' }).Count) {
    throw 'Submodule missing or not at baseline'
}
foreach ($p in @(
    (Join-Path $rustBin 'cargo.exe'),
    (Join-Path $rustBin 'rustc.exe'),
    (Join-Path $cargoTools 'cargo-ndk.exe'),
    (Join-Path $llvm 'clang.exe'),
    (Join-Path $llvm 'llvm-readelf.exe'),
    (Join-Path $ndk 'source.properties'),
    (Join-Path $AndroidSdk 'platforms\android-36\android.jar'),
    (Join-Path $AndroidSdk 'build-tools\35.0.0\aapt2.exe'),
    (Join-Path $AndroidSdk 'platform-tools\adb.exe'),
    (Join-Path $JavaHome 'bin\java.exe'),
    (Join-Path $LibClangPath 'libclang.dll'),
    (Join-Path $CacheRoot 'pub-cache'),
    (Join-Path $RepoRoot 'flutter\.dart_tool\package_config.json'),
    (Join-Path $vcpkgRoot 'vcpkg.exe'),
    $flutter
)) {
    if (!(Test-Path -LiteralPath $p)) { throw "Missing input: $p" }
}
$fv = Get-Content -Raw (Join-Path $flutterRoot 'bin\cache\flutter.version.json') | ConvertFrom-Json
if ($fv.frameworkVersion -ne '3.24.5') { throw 'Unexpected Flutter version' }
$ndkVersion = Get-Content -LiteralPath (Join-Path $ndk 'source.properties')
if (!($ndkVersion -match '^Pkg.Revision\s*=\s*28\.2\.13676358$')) {
    throw 'Unexpected NDK revision'
}
$vcpkgCommit = (& git -C $vcpkgRoot rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $vcpkgCommit -ne '9e593bb18ea69cc5095e012465dcd675a822ed0d') {
    throw 'Unexpected vcpkg revision'
}
# Windows-host cross builds use the same locked OpenSSL 3.5.4 source, built
# separately with Unix-compatible shell paths. Do not affect host dependencies.
foreach ($sslFile in @('lib\libssl.a','lib\libcrypto.a','include\openssl\opensslv.h')) {
    if (!(Test-Path -LiteralPath (Join-Path $OpenSslRoot $sslFile) -PathType Leaf)) {
        throw "Missing pinned Android OpenSSL input: $sslFile"
    }
}
$sslVersion = Get-Content -LiteralPath (Join-Path $OpenSslRoot 'include\openssl\opensslv.h')
if (!($sslVersion -match '^#\s*define\s+OPENSSL_VERSION_MAJOR\s+3\s*$') -or
    !($sslVersion -match '^#\s*define\s+OPENSSL_VERSION_MINOR\s+5\s*$') -or
    !($sslVersion -match '^#\s*define\s+OPENSSL_VERSION_PATCH\s+4\s*$')) {
    throw 'Android OpenSSL version differs from Cargo.lock'
}
# The Windows-host libsodium-sys build script selects a desktop archive even
# for Android. Supply the verified target archive only to Android rustc.
$sodiumLib = Join-Path $SodiumRoot 'lib\libsodium.a'
$sodiumHeader = Join-Path $SodiumRoot 'include\sodium\version.h'
if (!(Test-Path -LiteralPath $sodiumLib -PathType Leaf) -or
    !(Test-Path -LiteralPath $sodiumHeader -PathType Leaf)) {
    throw 'Missing pinned Android libsodium inputs'
}
if (!((Get-Content -LiteralPath $sodiumHeader) -match '^#define SODIUM_VERSION_STRING "1\.0\.18"$')) {
    throw 'Android libsodium version differs from locked source'
}
# Preserve existing target flags; reject ambiguous global flags rather than
# letting them override the target-specific library path.
if ($env:RUSTFLAGS -or $env:CARGO_ENCODED_RUSTFLAGS) {
    throw 'Global Rust flags would override the isolated Android configuration'
}
$sodiumLibDir = (Split-Path $sodiumLib -Parent).Replace('\','/')
if ($sodiumLibDir -match '\s') { throw 'Android sodium path must not contain spaces' }
$androidFlags = ($env:CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS + " -Lnative=$sodiumLibDir").Trim()
$vars = @{
    CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS = $androidFlags
    # cc-rs appends an unversioned target on Windows; enforce the same API 21
    # as the upstream NDK wrapper, rather than raising the minimum Android API.
    CFLAGS_aarch64_linux_android = ($env:CFLAGS_aarch64_linux_android + ' --target=aarch64-linux-android21').Trim()
    CXXFLAGS_aarch64_linux_android = ($env:CXXFLAGS_aarch64_linux_android + ' --target=aarch64-linux-android21').Trim()
    AARCH64_LINUX_ANDROID_OPENSSL_NO_VENDOR = '1'
    AARCH64_LINUX_ANDROID_OPENSSL_DIR = $OpenSslRoot
    AARCH64_LINUX_ANDROID_OPENSSL_STATIC = '1'
    PATH = "$rustBin;$cargoTools;$JavaHome\bin;$flutterRoot\bin;$env:PATH"
    RUSTC = (Join-Path $rustBin 'rustc.exe')
    RUSTDOC = (Join-Path $rustBin 'rustdoc.exe')
    ANDROID_HOME = $AndroidSdk
    ANDROID_SDK_ROOT = $AndroidSdk
    ANDROID_NDK_HOME = $ndk
    ANDROID_NDK_ROOT = $ndk
    JAVA_HOME = $JavaHome
    LIBCLANG_PATH = $LibClangPath
    VCPKG_ROOT = $vcpkgRoot
    VCPKG_INSTALLED_ROOT = $installed
    CARGO_TARGET_DIR = $targetDir
    PUB_CACHE = (Join-Path $CacheRoot 'pub-cache')
    GRADLE_USER_HOME = (Join-Path $CacheRoot 'gradle')
    FLUTTER_SUPPRESS_ANALYTICS = 'true'
    CI = 'true'
    CARGO_BUILD_JOBS = '1'
}
$old = @{}
foreach ($name in $vars.Keys) {
    $old[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,$vars[$name],'Process')
}
Push-Location $RepoRoot
try {
    $rustVersion = (& rustc --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $rustVersion -notmatch '^rustc 1\.98\.1 ') {
        throw "Unexpected Rust compiler: $rustVersion"
    }
    $rustTargetLib = (& rustc --print target-libdir --target $target | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $rustTargetLib)) {
        throw 'Rust Android target library missing'
    }
    $ndkToolVersion = (& cargo ndk --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $ndkToolVersion -ne 'cargo-ndk 3.1.2') {
        throw "Unexpected cargo-ndk: $ndkToolVersion"
    }
    "BASELINE_COMMIT=$head"
    "RUST_VERSION=$rustVersion"
    "NDK_TOOL_VERSION=$ndkToolVersion"
    'ANDROID_TOOLCHAIN_PRECHECK_PASS'

    $libDir = Join-Path $installed 'arm64-android\lib'
    $deps = @('libaom.a','libvpx.a','libyuv.a','libopus.a','libavcodec.a','libavutil.a','libndk_compat.a')
    $missing = @($deps | Where-Object { !(Test-Path (Join-Path $libDir $_)) })
    if ($missing.Count) {
        "ANDROID_DEPS_NOT_READY=$($missing -join ',')"
        if ($Mode -eq 'Check') { return }
        throw 'Required native libraries missing'
    }
    'ANDROID_NATIVE_DEPENDENCY_PRECHECK_PASS'
    if ($Mode -eq 'Check') { return }
    $drive = [IO.Path]::GetPathRoot($targetDir)
    if (([IO.DriveInfo]::new($drive)).AvailableFreeSpace -lt 20GB) {
        throw 'Less than 20 GB free on native build drive'
    }

    & cargo ndk --platform 21 --target $target build --locked --release --features flutter,hwcodec --jobs 1
    $code = $LASTEXITCODE
    "ANDROID_NATIVE_EXIT=$code"
    if ($code -ne 0) { throw "Native Android compilation failed: $code" }
    $so = Join-Path $targetDir "$target\release\liblibrustdesk.so"
    if (!(Test-Path $so)) { throw 'Missing native output' }
    $header = (& (Join-Path $llvm 'llvm-readelf.exe') -h $so | Out-String)
    if ($LASTEXITCODE -ne 0 -or $header -notmatch 'Machine:\s+AArch64' -or $header -notmatch 'Type:\s+DYN') {
        throw 'Native output is not an AArch64 shared library'
    }
    "ANDROID_NATIVE_SHA256=$((Get-FileHash $so).Hash)"
    if ($Mode -eq 'Native') { return }

    # Refuse to replace user-supplied native inputs. Only generated ignored outputs are permitted.
    $jni = Join-Path $RepoRoot 'flutter\android\app\src\main\jniLibs\arm64-v8a'
    $cpp = Join-Path $ndk 'toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\aarch64-linux-android\libc++_shared.so'
    if (!(Test-Path $cpp)) { throw 'NDK C++ runtime missing' }
    foreach ($f in @('librustdesk.so','libc++_shared.so')) {
        & git -C $RepoRoot check-ignore --quiet "flutter/android/app/src/main/jniLibs/arm64-v8a/$f"
        if ($LASTEXITCODE -ne 0) { throw "Generated native path not ignored: $f" }
    }
    New-Item -ItemType Directory -Path $jni -Force | Out-Null
    foreach ($entry in @(@($so,'librustdesk.so'),@($cpp,'libc++_shared.so'))) {
        $dst = Join-Path $jni $entry[1]
        if (Test-Path $dst) {
            if ((Get-FileHash $dst).Hash -ne (Get-FileHash $entry[0]).Hash) {
                throw "Existing native input differs: $dst"
            }
        } else { Copy-Item -LiteralPath $entry[0] -Destination $dst }
    }
    Set-Location (Join-Path $RepoRoot 'flutter')
    & $flutter build apk --debug --target-platform android-arm64 --no-pub
    $code = $LASTEXITCODE
    "ANDROID_DEBUG_PACKAGE_EXIT=$code"
    if ($code -ne 0) { throw "Android debug package failed: $code" }
    $apk = Join-Path $RepoRoot 'flutter\build\app\outputs\flutter-apk\app-debug.apk'
    if (!(Test-Path $apk)) { throw 'APK missing' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($apk)
    try {
        foreach ($name in @('lib/arm64-v8a/librustdesk.so','lib/arm64-v8a/libc++_shared.so')) {
            if (!$zip.GetEntry($name)) { throw "APK missing required file: $name" }
        }
    } finally { $zip.Dispose() }
    "ANDROID_DEBUG_APK=$apk"
    "ANDROID_DEBUG_APK_SHA256=$((Get-FileHash $apk).Hash)"
    'ANDROID_DEBUG_BASELINE_BUILD_PASS'
} finally {
    Pop-Location
    foreach ($name in $old.Keys) {
        [Environment]::SetEnvironmentVariable($name,$old[$name],'Process')
    }
}
