[CmdletBinding()]
param(
    [ValidateSet('Check','Native')][string]$Mode = 'Check',
    [string]$RepoRoot = 'D:\demo2\rustdesk',
    [string]$ToolchainRoot = 'D:\demo2\bk-remote-toolchains'
)
$ErrorActionPreference = 'Stop'
$baseline = 'a0c0963c483fc8f1aeed4547787d1673adcb583c'
$common = '450cc1d7b729cfa8d19b5a7527c9cc2fe54cf5eb'
$image = 'sha256:3632b70443662a28c2c4929ed04ae652e1504cb0f42f05cbc559e50dd1cff3a4'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ToolchainRoot = (Resolve-Path -LiteralPath $ToolchainRoot).Path
function Assert-Native([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label failed: $LASTEXITCODE" }
}
if ((& git -C $RepoRoot rev-parse HEAD | Out-String).Trim() -ne $baseline) {
    throw 'Unexpected client baseline'
}
Assert-Native 'Client revision'
& git -C $RepoRoot diff --quiet HEAD --
Assert-Native 'Tracked client source differs'
$sub = Join-Path $RepoRoot 'libs\hbb_common'
if ((& git -C $sub rev-parse HEAD | Out-String).Trim() -ne $common) {
    throw 'Unexpected common submodule revision'
}
Assert-Native 'Submodule revision'
& git -C $sub diff --quiet HEAD --
Assert-Native 'Tracked submodule source differs'
$vcpkg = Join-Path $ToolchainRoot 'vcpkg-android-installed'
$openssl = Join-Path $ToolchainRoot 'ssl-android-3.5.4\install'
$bash = Join-Path $RepoRoot 'scripts\bk-remote\android-linux-native.sh'
foreach ($p in @($bash, $vcpkg, $openssl,
    (Join-Path $RepoRoot 'src\bridge_generated.rs'),
    (Join-Path $RepoRoot 'src\bridge_generated.io.rs'))) {
    if (!(Test-Path -LiteralPath $p)) { throw "Missing input: $p" }
}
$pin = (& git -C (Join-Path $ToolchainRoot 'vcpkg') rev-parse HEAD | Out-String).Trim()
Assert-Native 'vcpkg revision'
if ($pin -ne '9e593bb18ea69cc5095e012465dcd675a822ed0d') { throw 'Wrong vcpkg pin' }
$free = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($ToolchainRoot))).AvailableFreeSpace
if ($free -lt 25GB) { throw 'Less than 25GB free on build drive' }
$os = (& docker info --format '{{.OSType}}' | Out-String).Trim()
Assert-Native 'Docker engine'
if ($os -ne 'linux') { throw 'A Linux Docker engine is required' }
& docker image inspect $image --format '{{.Id}}'
Assert-Native 'Pinned Linux build image'
# Parse Bash in a network-isolated disposable container without touching inputs.
$scriptDir = Split-Path $bash -Parent
& docker run --rm --network none --memory 512m --cpus 1 --mount "type=bind,source=$scriptDir,target=/scripts,readonly" --entrypoint /bin/bash $image -n /scripts/android-linux-native.sh
Assert-Native 'Bash syntax'
"ANDROID_LINUX_CHECK_PASS freeGB=$([math]::Round($free/1GB,2))"
if ($Mode -eq 'Check') { return }
# Never overwrite another run or mount a development tree writable.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$root = Join-Path $ToolchainRoot "linux-android-g1-$stamp"
$inputDir = Join-Path $root 'inputs'
$evidence = Join-Path $root 'evidence'
if (Test-Path $root) { throw 'Run directory exists' }
New-Item -ItemType Directory -Path $inputDir,$evidence | Out-Null
& git -C $RepoRoot archive --format=tar "--output=$inputDir\client.tar" $baseline
Assert-Native 'Client source archive'
& git -C $sub archive --format=tar "--output=$inputDir\hbb_common.tar" $common
Assert-Native 'Submodule archive'
Copy-Item -LiteralPath (Join-Path $RepoRoot 'src\bridge_generated.rs'),(Join-Path $RepoRoot 'src\bridge_generated.io.rs') -Destination $inputDir
[IO.File]::WriteAllText((Join-Path $inputDir 'baseline.txt'),"$baseline"+[char]10,[Text.UTF8Encoding]::new($false))
$scriptText = [IO.File]::ReadAllText($bash).Replace([string][char]13+[char]10,[string][char]10)
[IO.File]::WriteAllText((Join-Path $inputDir 'android-linux-native.sh'),$scriptText,[Text.UTF8Encoding]::new($false))
$hashLines = Get-ChildItem -LiteralPath $inputDir -File | Sort-Object Name | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
}
[IO.File]::WriteAllText((Join-Path $inputDir 'SHA256SUMS'),($hashLines -join [char]10)+[char]10,[Text.UTF8Encoding]::new($false))
$name = "bk-remote-g1-$stamp"
$volume = "$name-work"
$log = Join-Path $evidence 'native-build.log'
"RUN_DIR=$root"
"CONTAINER=$name"
"VOLUME=$volume"
# A dedicated container and volume, no other projects' writable mounts.
# Retain the named container and volume for inspection; no production access.
$args = @('run','--name',$name,'--memory','6g','--cpus','2',
    '--mount',"type=bind,source=$inputDir,target=/inputs,readonly",
    '--mount',"type=bind,source=$evidence,target=/evidence",
    '--mount',"type=bind,source=$vcpkg,target=/vcpkg/installed,readonly",
    '--mount',"type=bind,source=$openssl,target=/openssl,readonly",
    '--mount',"type=volume,source=$volume,target=/work",
    '--entrypoint','/bin/bash',$image,'/inputs/android-linux-native.sh')
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & docker @args 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $log
    $rc = $LASTEXITCODE
} finally { $ErrorActionPreference = $previous }
[IO.File]::WriteAllText((Join-Path $evidence 'exit-code.txt'),[string]$rc)
"ANDROID_LINUX_RUN_EXIT=$rc"
if ($rc -ne 0) { throw "Linux Android build failed; evidence: $evidence" }
if (!(Test-Path (Join-Path $evidence 'linux-native-output.sha256'))) { throw 'Native output evidence missing' }
