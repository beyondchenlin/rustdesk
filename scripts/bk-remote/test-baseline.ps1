[CmdletBinding()]
param(
    [ValidateSet('Check','Ui','Native','All')][string]$Mode = 'Check',
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..\..'),
    [Parameter(Mandatory=$true)][string]$FlutterSdk,
    [Parameter(Mandatory=$true)][string]$PubCache,
    [Parameter(Mandatory=$true)][string]$VcpkgRoot,
    [Parameter(Mandatory=$true)][string]$LibClangPath,
    [string]$BaselineCommit = 'a0c0963c483fc8f1aeed4547787d1673adcb583c'
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$flutter = Join-Path $FlutterSdk 'bin\flutter.bat'
$dart = Join-Path $FlutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
$versionFile = Join-Path $FlutterSdk 'bin\cache\flutter.version.json'
$version = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
if ($version.frameworkVersion -ne '3.24.5') {
    throw "Expected upstream Flutter 3.24.5, found $($version.frameworkVersion)"
}
foreach ($p in @($flutter,$dart,$PubCache,$VcpkgRoot,
    (Join-Path $LibClangPath 'libclang.dll'),
    (Join-Path $RepoRoot 'flutter\.dart_tool\package_config.json'))) {
    if (!(Test-Path -LiteralPath $p)) { throw "Missing input: $p" }
}
$head = (& git -C $RepoRoot rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $BaselineCommit) {
    throw "Baseline commit mismatch: $head"
}
& git -C $RepoRoot diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'Tracked baseline has local changes' }
$extra = @(& git -C $RepoRoot ls-files --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Cannot check untracked files' }
$unexpected = @($extra | Where-Object {
    $_ -notmatch '^(docs/|assets/brand/|scripts/bk-remote/)'
})
if ($unexpected.Count -ne 0) {
    throw "Unexpected untracked source: $($unexpected -join ', ')"
}
$expectedVcpkg = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
$actualVcpkg = (& git -C $VcpkgRoot rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualVcpkg -ne $expectedVcpkg) {
    throw "vcpkg baseline mismatch: $actualVcpkg"
}
"BASELINE_COMMIT=$head"
"FLUTTER_VERSION=$($version.frameworkVersion)"
"VCPKG_COMMIT=$actualVcpkg"
'PRECHECK_PASS'
if ($Mode -eq 'Check') { return }

$envValues = @{
    PUB_CACHE = $PubCache
    FLUTTER_SUPPRESS_ANALYTICS = 'true'
    CI = 'true'
    LIBCLANG_PATH = $LibClangPath
    VCPKG_ROOT = $VcpkgRoot
    VCPKG_DEFAULT_TRIPLET = 'x64-windows-static'
    VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
}
$old = @{}
foreach ($name in $envValues.Keys) {
    $old[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,$envValues[$name],'Process')
}
Push-Location $RepoRoot
try {
    if ($Mode -in @('Ui','All')) {
        Set-Location (Join-Path $RepoRoot 'flutter')
        $testArgs = @('test','--no-pub','--reporter','expanded',
            'test/server_settings_dialog_test.dart',
            'test/account_password_login_test.dart',
            'test/request_approval_menu_test.dart',
            'test/android_file_transfer_setup_test.dart')
        & $flutter @testArgs
        $code = $LASTEXITCODE
        "UI_BASELINE_EXIT=$code"
        if ($code -ne 0) { throw "UI baseline failed: $code" }
    }
    if ($Mode -in @('Native','All')) {
        Set-Location $RepoRoot
        # Debug library smoke only; release with hardware codecs is a separate gate.
        & cargo build --locked --offline --lib --features flutter --jobs 1
        $code = $LASTEXITCODE
        "NATIVE_DEBUG_BASELINE_EXIT=$code"
        if ($code -ne 0) { throw "Native baseline failed: $code" }
    }
} finally {
    Pop-Location
    foreach ($name in $old.Keys) {
        [Environment]::SetEnvironmentVariable($name,$old[$name],'Process')
    }
}
'REQUESTED_BASELINE_STEPS_PASS'
