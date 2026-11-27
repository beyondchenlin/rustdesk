[CmdletBinding()]
param(
    [ValidateSet('Check','Package')][string]$Mode = 'Check',
    [string]$NativeRunRoot,
    [string]$RepoRoot = 'D:\demo2\rustdesk',
    [string]$ToolchainRoot = 'D:\demo2\bk-remote-toolchains',
    [string]$AndroidSdk = 'D:\demo2\bk-remote-android-sdk',
    [string]$CacheRoot = 'D:\demo2\bk-remote-cache',
    [string]$JavaHome = 'D:\demo1\BKSOP-tools\jdk17\jdk-17.0.21.0.2+1'
)
$ErrorActionPreference = 'Stop'
$baseline = 'a0c0963c483fc8f1aeed4547787d1673adcb583c'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$flutterRoot = Join-Path $ToolchainRoot 'flutter-3.24.5'
$flutter = Join-Path $flutterRoot 'bin\flutter.bat'
$llvm = Join-Path $AndroidSdk 'ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe'
$tools = Join-Path $AndroidSdk 'build-tools\35.0.0'
$pubCache = Join-Path $CacheRoot 'pub-cache'
$gradleHome = Join-Path $CacheRoot 'gradle'
$dartBridge = @{
    'flutter/lib/generated_bridge.dart' = 'B68EA66847D48179FD3DB828C516619C28D60853147D9FF99D83D9CE19951D8B'
    'flutter/lib/generated_bridge.freezed.dart' = '5C41889F95D46EF4B57EBA34FC4C29B51E76EFAADA2ABF51E6C0CBBC112AE3D4'
}
function Assert-Native([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label failed: $LASTEXITCODE" }
}
function Assert-Source {
    if ((& git -C $RepoRoot rev-parse HEAD | Out-String).Trim() -ne $baseline) { throw 'Wrong client baseline revision' }
    Assert-Native 'Client revision'
    & git -C $RepoRoot diff --quiet HEAD --
    Assert-Native 'Tracked client source differs'
    $sub = Join-Path $RepoRoot 'libs\hbb_common'
    if ((& git -C $sub rev-parse HEAD | Out-String).Trim() -ne '450cc1d7b729cfa8d19b5a7527c9cc2fe54cf5eb') { throw 'Wrong hbb_common submodule revision' }
    Assert-Native 'Submodule revision'
    & git -C $sub diff --quiet HEAD --
    Assert-Native 'Tracked submodule source differs'
    foreach ($name in $dartBridge.Keys) {
        if ((Get-FileHash (Join-Path $RepoRoot $name)).Hash -ne $dartBridge[$name]) { throw "Dart bridge changed: $name" }
    }
}
Assert-Source
foreach ($p in @($flutter,$llvm,(Join-Path $JavaHome 'bin\java.exe'),
    (Join-Path $tools 'apksigner.bat'),(Join-Path $tools 'aapt2.exe'),
    (Join-Path $AndroidSdk 'platforms\android-36\android.jar'),
    (Join-Path $RepoRoot 'flutter\pubspec.lock'),
    (Join-Path $RepoRoot 'flutter\.dart_tool\package_config.json'),
    $pubCache,$gradleHome)) {
    if (!(Test-Path -LiteralPath $p)) { throw "Missing package input: $p" }
}
$fv = Get-Content -Raw (Join-Path $flutterRoot 'bin\cache\flutter.version.json') | ConvertFrom-Json
if ($fv.frameworkVersion -ne '3.24.5') { throw 'Wrong Flutter version' }
foreach ($name in @('librustdesk.so','libc++_shared.so')) {
    & git -C $RepoRoot check-ignore --quiet "flutter/android/app/src/main/jniLibs/arm64-v8a/$name"
    if ($LASTEXITCODE -ne 0) { throw 'Native output path not ignored' }
}
$os = (& docker info --format '{{.OSType}}' | Out-String).Trim()
Assert-Native 'Docker engine'
if ($os -ne 'linux') { throw 'A Linux Docker engine is required' }
'ANDROID_LINUX_PACKAGE_PREFLIGHT_PASS'
if ($Mode -eq 'Check') { return }
if ([string]::IsNullOrWhiteSpace($NativeRunRoot)) { throw 'NativeRunRoot required' }
$NativeRunRoot = (Resolve-Path -LiteralPath $NativeRunRoot).Path
$evidence = Join-Path $NativeRunRoot 'evidence'
$inputs = Join-Path $NativeRunRoot 'inputs'
if ((Get-Content -Raw (Join-Path $evidence 'exit-code.txt')).Trim() -ne '0') { throw 'Native run did not complete successfully' }
if ((Get-Content -Raw (Join-Path $inputs 'baseline.txt')).Trim() -ne $baseline) { throw 'Native baseline differs' }
foreach ($name in @('bridge_generated.rs','bridge_generated.io.rs')) {
    if ((Get-FileHash (Join-Path $inputs $name)).Hash -ne (Get-FileHash (Join-Path $RepoRoot "src\$name")).Hash) { throw 'Native bridge differs from current baseline' }
}
$manifest = @{}
foreach ($line in (Get-Content (Join-Path $evidence 'linux-native-output.sha256'))) {
    if ($line -notmatch '^([a-fA-F0-9]{64})  (liblibrustdesk\.so|libc\+\+_shared\.so)$') { throw 'Invalid native output manifest' }
    if ($manifest.ContainsKey($Matches[2])) { throw 'Duplicate native output manifest entry' }
    $manifest[$Matches[2]] = $Matches[1].ToUpperInvariant()
}
if ($manifest.Count -ne 2) { throw 'Incomplete native output manifest' }
$jni = Join-Path $RepoRoot 'flutter\android\app\src\main\jniLibs\arm64-v8a'
$destinations = @{'liblibrustdesk.so'='librustdesk.so'; 'libc++_shared.so'='libc++_shared.so'}
foreach ($name in $destinations.Keys) {
    $source = Join-Path $evidence $name
    if ((Get-FileHash $source).Hash -ne $manifest[$name]) { throw "Native hash differs: $name" }
    $elf = (& $llvm -h $source | Out-String)
    if ($LASTEXITCODE -ne 0 -or $elf -notmatch 'Machine:\s+AArch64' -or $elf -notmatch 'Type:\s+DYN') { throw "Wrong native architecture: $name" }
    $dst = Join-Path $jni $destinations[$name]
    if ((Test-Path $dst) -and ((Get-FileHash $dst).Hash -ne $manifest[$name])) { throw "Refusing to overwrite different native input: $dst" }
}
New-Item -ItemType Directory -Path $jni -Force | Out-Null
foreach ($name in $destinations.Keys) {
    $dst = Join-Path $jni $destinations[$name]
    if (!(Test-Path $dst)) { Copy-Item -LiteralPath (Join-Path $evidence $name) -Destination $dst }
}
$envVars = @{
    JAVA_HOME = $JavaHome
    ANDROID_HOME = $AndroidSdk
    ANDROID_SDK_ROOT = $AndroidSdk
    PUB_CACHE = $pubCache
    PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    GRADLE_USER_HOME = $gradleHome
    PATH = "$JavaHome\bin;$flutterRoot\bin;$env:PATH"
    FLUTTER_SUPPRESS_ANALYTICS = 'true'
    CI = 'true'
}
$old = @{}
foreach ($name in $envVars.Keys) {
    $old[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,$envVars[$name],'Process')
}
$gradleProps = Join-Path $gradleHome 'gradle.properties'
$requiredProps = @(
    'org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8',
    'org.gradle.workers.max=2',
    'org.gradle.parallel=false',
    'kotlin.compiler.execution.strategy=in-process',
    'kotlin.incremental=false'
)
if (Test-Path $gradleProps) {
    $existing = Get-Content $gradleProps
    foreach ($line in $requiredProps) {
        $key = $line.Split('=')[0]
        $match = @($existing | Where-Object { $_ -match ('^\s*' + [regex]::Escape($key) + '=') })
        if ($match.Count -gt 0 -and $match[0] -ne $line) { throw "Conflicting isolated Gradle setting: $key" }
        if ($match.Count -eq 0) { Add-Content -LiteralPath $gradleProps -Value $line -Encoding utf8 }
    }
} else {
    [IO.File]::WriteAllLines($gradleProps,[string[]]$requiredProps,[Text.UTF8Encoding]::new($false))
}
$lockPath = Join-Path $RepoRoot 'flutter\pubspec.lock'
$lockBefore = (Get-FileHash $lockPath).Hash
$packageConfig = Join-Path $RepoRoot 'flutter\.dart_tool\package_config.json'
$packageLog = Join-Path $evidence 'pub-cache-relocation.log'
$buildLog = Join-Path $evidence 'android-debug-package.log'
$buildExit = Join-Path $evidence 'android-debug-package.exit-code.txt'
Push-Location (Join-Path $RepoRoot 'flutter')
try {
    # Preserve the exact package lock and package versions already used by this
    # baseline. Relocate only generated package_config roots after copying the
    # complete existing Pub cache to D:. Do not run a new dependency resolution.
    $packageConfigBackup = Join-Path $evidence 'package_config.before-relocation.json'
    if (!(Test-Path $packageConfigBackup)) {
        Copy-Item -LiteralPath $packageConfig -Destination $packageConfigBackup
    }
    $rawConfig = [IO.File]::ReadAllText($packageConfig)
    $sourceCacheUri = 'file:///C:/Users/ai/AppData/Local/Pub/Cache/'
    $targetCacheUri = 'file:///D:/demo2/bk-remote-cache/pub-cache/'
    $rawConfig = $rawConfig.Replace($sourceCacheUri,$targetCacheUri)
    [IO.File]::WriteAllText($packageConfig,$rawConfig,[Text.UTF8Encoding]::new($false))
    $pc = Get-Content -Raw $packageConfig | ConvertFrom-Json
    $cRoots = @($pc.packages | Where-Object { $_.rootUri -match 'file:///C:/' -or $_.rootUri -match 'C:\\\\Users\\\\' })
    if ($cRoots.Count -gt 0) {
        $names = ($cRoots | Select-Object -First 10 -ExpandProperty name) -join ','
        throw "Pub package roots still reference C:; examples: $names"
    }
    $dRoots = @($pc.packages | Where-Object { $_.rootUri -match 'file:///D:/demo2/bk-remote-cache/pub-cache/' })
    if ($dRoots.Count -lt 100) { throw "Expected at least 100 relocated Pub packages; found $($dRoots.Count)" }
    foreach ($package in $dRoots) {
        $packagePath = ([Uri]$package.rootUri).LocalPath
        if (!(Test-Path -LiteralPath $packagePath -PathType Container)) {
            throw "Relocated Pub package directory missing: $($package.name)"
        }
    }
    if ((Get-FileHash $lockPath).Hash -ne $lockBefore) { throw 'pubspec.lock changed during cache relocation' }
    [IO.File]::WriteAllLines($packageLog,[string[]]@(
        'Dependency resolution intentionally skipped.',
        'The existing locked package_config.json was relocated from C: to D: after copying the complete existing Pub cache.',
        "Relocated package roots: $($dRoots.Count)",
        "pubspec.lock SHA256: $lockBefore"
    ),[Text.UTF8Encoding]::new($false))
    "PUB_PACKAGE_ROOTS_D_DRIVE=$($dRoots.Count)"
    "PUBSPEC_LOCK_SHA256=$lockBefore"
    # No build may be running while generated output is cleared.
    $active = @(Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -match 'flutter_tools\.snapshot.*build apk|gradlew\.bat.*assembleDebug'
    })
    if ($active.Count -gt 0) { throw 'Another Android package build is active' }
    $buildDir = Join-Path (Get-Location) 'build'
    if ($env:BK_REMOTE_FORCE_CLEAN_BUILD -eq '1' -and (Test-Path $buildDir)) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
    # Debug APK only. Never use a production signing key or install/launch it.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $flutter build apk --debug --split-per-abi --target-platform android-arm64 --no-pub 2>&1 |
            ForEach-Object {$_.ToString()} | Tee-Object -FilePath $buildLog
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    [IO.File]::WriteAllText($buildExit,[string]$rc)
    "ANDROID_DEBUG_PACKAGE_EXIT=$rc"
    if ($rc -ne 0) { throw "Flutter package failed: $rc" }
    Assert-Source
    if ((Get-FileHash $lockPath).Hash -ne $lockBefore) { throw 'pubspec.lock changed during build' }
    $apk = Join-Path $RepoRoot 'flutter\build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk'
    if (!(Test-Path $apk)) { throw 'Debug APK output missing' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $abiDirs = @($zip.Entries |
            Where-Object { $_.FullName -match '^lib/[^/]+/[^/]+\.so$' } |
            ForEach-Object { $_.FullName.Split('/')[1] } |
            Sort-Object -Unique)
        if ($abiDirs.Count -ne 1 -or $abiDirs[0] -ne 'arm64-v8a') {
            throw "APK contains unsupported ABI directories: $($abiDirs -join ',')"
        }
        foreach ($name in $destinations.Keys) {
            $entry = $zip.GetEntry("lib/arm64-v8a/$($destinations[$name])")
            if (!$entry) { throw "APK native entry missing: $name" }
            $stream = $entry.Open()
            try {
                if ((Get-FileHash -InputStream $stream).Hash -ne $manifest[$name]) { throw "APK native bytes differ: $name" }
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    & (Join-Path $tools 'apksigner.bat') verify --verbose $apk
    if ($LASTEXITCODE -ne 0) { throw 'Debug APK signature verification failed' }
    $badging = (& (Join-Path $tools 'aapt2.exe') dump badging $apk | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'APK metadata verification failed' }
    $gradle = Get-Content (Join-Path $RepoRoot 'flutter\android\app\build.gradle') -Raw
    $id = [regex]::Match($gradle,'applicationId\s+["'']([^"'']+)["'']').Groups[1].Value
    if (!$id -or $badging -notmatch ("package: name='" + [regex]::Escape($id) + "'")) { throw 'APK application ID differs from the Gradle source' }
    $nativeCode = [regex]::Match($badging,"(?m)^native-code:\s*(.+)$")
    if (!$nativeCode.Success -or $nativeCode.Groups[1].Value.Trim() -ne "'arm64-v8a'") {
        throw "APK native-code declaration is not ARM64-only: $($nativeCode.Groups[1].Value)"
    }
    $badging | Select-String '^(package:|sdkVersion:|targetSdkVersion:|native-code:)' | ForEach-Object {$_.Line}
    $final = Join-Path $evidence 'rustdesk-original-arm64-debug.apk'
    if (Test-Path $final) { throw 'Refusing to overwrite prior package evidence' }
    Copy-Item -LiteralPath $apk -Destination $final
    "ANDROID_DEBUG_APK=$final"
    "ANDROID_DEBUG_APK_BYTES=$((Get-Item $final).Length)"
    "ANDROID_DEBUG_APK_SHA256=$((Get-FileHash $final).Hash)"
    'ANDROID_LINUX_DEBUG_BASELINE_PACKAGE_PASS'
} finally {
    Pop-Location
    foreach ($name in $old.Keys) { [Environment]::SetEnvironmentVariable($name,$old[$name],'Process') }
}
