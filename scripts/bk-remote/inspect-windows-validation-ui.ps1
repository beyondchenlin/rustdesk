param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][string]$Evidence,
    [ValidateSet('launch','capture')][string]$Action = 'capture'
)
$ErrorActionPreference = 'Stop'
$bundlePath = [IO.Path]::GetFullPath($Bundle).TrimEnd('\')
$evidencePath = [IO.Path]::GetFullPath($Evidence)
$allowedRoot = 'D:\demo2\bk-remote-toolchains\'
if (!$bundlePath.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -or !$evidencePath.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Validation paths must stay within the BK toolchain directory.' }
$exe = Join-Path $bundlePath 'BK Remote.exe'
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Expected branded validation executable.' }
New-Item -ItemType Directory -Path $evidencePath -Force | Out-Null
$matching = @(Get-Process -Name 'BK Remote' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($Action -eq 'launch') {
    if ($matching.Count -ne 0) { throw 'This candidate is already running; use capture.' }
    $ownedProcess = Start-Process -FilePath $exe -WorkingDirectory $bundlePath -PassThru
    $ownedProcess.Id | Set-Content (Join-Path $evidencePath 'started-pid.txt')
}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BkUiEvidence {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
$windowProcess = $null
for ($attempt=0; $attempt -lt 100; $attempt++) {
    $windowProcess = Get-Process -Name 'BK Remote' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($null -ne $windowProcess) { break }
    Start-Sleep -Milliseconds 100
}
if ($null -eq $windowProcess) { throw 'No visible window for this candidate within 10 seconds.' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$hwnd = $windowProcess.MainWindowHandle
$foreground = [BkUiEvidence]::GetForegroundWindow()
[uint32]$foregroundOwner = 0
[BkUiEvidence]::GetWindowThreadProcessId($foreground, [ref]$foregroundOwner) | Out-Null
$foregroundProcess = Get-Process -Id $foregroundOwner -ErrorAction SilentlyContinue
if ($null -ne $foregroundProcess -and $foregroundProcess.Path -eq $exe) {
    $windowProcess = $foregroundProcess
    $hwnd = $foreground
}
[BkUiEvidence]::ShowWindow($hwnd, 9) | Out-Null
[BkUiEvidence]::SetForegroundWindow($hwnd) | Out-Null
$root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$null = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
Start-Sleep -Milliseconds 400
$nodes = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$tree = @()
for ($index=0; $index -lt [Math]::Min($nodes.Count, 600); $index++) {
    try {
        $current = $nodes.Item($index).Current
        $bounds = $current.BoundingRectangle
        $tree += [ordered]@{ index=$index; name=$current.Name; automation_id=$current.AutomationId; class_name=$current.ClassName; control_type=$current.ControlType.ProgrammaticName; enabled=$current.IsEnabled; offscreen=$current.IsOffscreen; bounds=@($bounds.X,$bounds.Y,$bounds.Width,$bounds.Height) }
    } catch { $tree += @{index=$index; error=$_.Exception.Message} }
}
$tree | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $evidencePath "$stamp-ui.json")
$rect = New-Object BkUiEvidence+Rect
if (![BkUiEvidence]::GetWindowRect($hwnd, [ref]$rect)) { throw 'Cannot read candidate window bounds.' }
$screenshot = $null
if ([BkUiEvidence]::GetForegroundWindow() -eq $hwnd -and $rect.Right -gt $rect.Left -and $rect.Bottom -gt $rect.Top) {
    $bitmap = New-Object Drawing.Bitmap ($rect.Right-$rect.Left),($rect.Bottom-$rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        $screenshot = Join-Path $evidencePath "$stamp-window.png"
        $bitmap.Save($screenshot, [Drawing.Imaging.ImageFormat]::Png)
        Copy-Item -LiteralPath $screenshot -Destination (Join-Path $evidencePath 'latest-window.png') -Force
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
$modules = @($windowProcess.Modules | Where-Object { $_.FileName.StartsWith($bundlePath + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.FileName })
$result = [ordered]@{time=(Get-Date -Format o); executable=$exe; pid=$windowProcess.Id; session_id=$windowProcess.SessionId; title=$windowProcess.MainWindowTitle; screenshot=$screenshot; ui_nodes=$nodes.Count; own_loaded_modules=$modules; installation_performed=$false}
$result | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $evidencePath "$stamp-result.json")
[pscustomobject]$result | Select-Object time,pid,title,screenshot,ui_nodes | ConvertTo-Json -Depth 4
